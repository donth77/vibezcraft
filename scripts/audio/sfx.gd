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


# Footstep — picks a random variant for the block's material.
func play_step(block_id: int) -> void:
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


# Tool snap — vanilla MC's random/break.ogg, played when a tool's
# durability hits zero and the stack is consumed.
func play_tool_break() -> void:
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


# Item pickup "pop" — vanilla MC's random/pop.ogg
func play_pickup() -> void:
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


func _material_for(block_id: int) -> String:
	match block_id:
		Blocks.STONE, Blocks.COBBLESTONE, Blocks.BEDROCK, Blocks.BRICK, Blocks.OBSIDIAN:
			return "stone"
		Blocks.DIRT, Blocks.GRASS, Blocks.LEAVES:
			return "grass"
		Blocks.SAND:
			return "sand"
		Blocks.LOG, Blocks.PLANKS, Blocks.CRAFTING_TABLE:
			return "wood"
		Blocks.GRAVEL, Blocks.FARMLAND:
			return "gravel"
	return ""


# Step-sound material — diverges from dig: leaves use the soft "cloth"
# variant, not grass-rustle (vanilla MC behavior).
func _step_material_for(block_id: int) -> String:
	if block_id == Blocks.LEAVES:
		return "cloth"
	return _material_for(block_id)
