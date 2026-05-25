extends Node

# Positional audio player for jukeboxes. Spawns AudioStreamPlayer3D
# nodes parented to a long-lived host (ChunkManager) so the record's
# sound radiates from its cell with vanilla-style 64 m falloff. The
# audio bus is `Master` (same as MusicPlayer); volume scales with the
# Music volume slider via _apply_music_volume below.
#
# Vanilla reference: BlockJukebox (Beta 1.4) calls World.playRecord
# which routes to the SoundManager's playStreaming with the record
# resource name. The sound plays ONCE — when the track finishes,
# vanilla's TileEntityRecordPlayer keeps the disc loaded but goes
# silent until the player ejects + reinserts. We mirror that: the
# AudioStreamPlayer3D's `finished` signal queue_free's the player so
# the next disc insert spawns a fresh one.

# Disc item_id → music track path. Mojang's "13" + "cat" sprites map
# to our custom tracks (First-Light = ambient piano open; Green-
# Distance = layered synth + piano warmer follow-up). Filename strings
# bind at runtime; missing files print one warning + silently no-op.
const _TRACKS: Dictionary = {
	# Resolved by id_from_name at JukeboxAudio._init time so we don't
	# have to depend on Items.gd's load order here.
	"music_disc_first_light": "res://assets/audio/music/First-Light.mp3",
	"music_disc_green_distance": "res://assets/audio/music/Green-Distance.mp3",
}

# Vanilla audible radius. Records are loud — they cut through the world
# music slider's quieter ambient pool. 64 m matches the playRecord
# packet's published range in vanilla SoundManager.
const _MAX_DISTANCE: float = 64.0
# 1.0 = falloff curve uses block-sized units. Default linear-distance
# attenuation drops to 0 at max_distance.
const _UNIT_SIZE: float = 1.0

# Vector3i (jukebox cell) → AudioStreamPlayer3D. One entry per playing
# jukebox; stops + erases on finished signal or explicit stop_disc.
var _players: Dictionary = {}
# Cached resolved Items.MUSIC_DISC_* → AudioStream so we don't load the
# same file every play.
var _stream_cache: Dictionary = {}


func _ready() -> void:
	# Resolve disc-id → AudioStream at boot so item id lookups in
	# play_disc are fast and so missing-file warnings surface early.
	for disc_name: String in _TRACKS:
		var disc_id: int = Items.id_from_name(disc_name)
		if disc_id < 0:
			push_warning("[JukeboxAudio] unknown disc %s in _TRACKS" % disc_name)
			continue
		var path: String = _TRACKS[disc_name]
		var stream: AudioStream = load(path) as AudioStream
		if stream == null:
			push_warning("[JukeboxAudio] missing audio file: %s" % path)
			continue
		_stream_cache[disc_id] = stream


# Start playback at `cell_pos` with the given disc. Stops any previous
# playback at that cell first (vanilla's "eject before insert" handles
# the disc item swap; we mirror it on the audio side too).
func play_disc(parent: Node, cell_pos: Vector3i, disc_id: int) -> void:
	stop_disc(cell_pos)
	var stream: AudioStream = _stream_cache.get(disc_id) as AudioStream
	if stream == null:
		# Either the disc id isn't in _TRACKS (caller's bug) or the audio
		# file is missing. Silent fail — the tile entity still tracks the
		# disc; only audible playback is skipped.
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.bus = &"Master"
	player.max_distance = _MAX_DISTANCE
	player.unit_size = _UNIT_SIZE
	player.attenuation_filter_cutoff_hz = 5000.0
	parent.add_child(player)
	# Cell-center anchor so the sound radiates from the visible jukebox
	# block rather than its corner.
	player.global_position = Vector3(cell_pos) + Vector3(0.5, 0.5, 0.5)
	# Auto-stop when the track finishes — vanilla goes silent after one
	# play; the disc stays in the slot until ejected. Use a lambda
	# capturing cell_pos so the dictionary stays in sync.
	player.finished.connect(func() -> void: stop_disc(cell_pos))
	player.play()
	_players[cell_pos] = player


# Stop + free the player at `cell_pos`. Safe to call on an empty cell.
func stop_disc(cell_pos: Vector3i) -> void:
	if not _players.has(cell_pos):
		return
	var player: AudioStreamPlayer3D = _players[cell_pos] as AudioStreamPlayer3D
	if is_instance_valid(player):
		player.stop()
		player.queue_free()
	_players.erase(cell_pos)


# Convenience used by debug / inspector code. Returns true if a disc is
# currently audible from this cell (track hasn't finished yet).
func is_playing(cell_pos: Vector3i) -> bool:
	return _players.has(cell_pos)
