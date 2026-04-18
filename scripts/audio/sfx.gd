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


# Item pickup "pop" — vanilla MC's random/pop.ogg
func play_pickup() -> void:
	var stream: AudioStream = _stream_cache.get(_PICKUP_SOUND)
	if stream == null:
		stream = load(_PICKUP_SOUND) as AudioStream
		_stream_cache[_PICKUP_SOUND] = stream
	var player: AudioStreamPlayer = _players[_next_player]
	_next_player = (_next_player + 1) % POOL_SIZE
	player.stream = stream
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
		Blocks.LOG, Blocks.PLANKS:
			return "wood"
	return ""
