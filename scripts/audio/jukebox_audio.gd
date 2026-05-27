extends Node

# gdlint: disable=class-definitions-order

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

# Disc item_id → music track path. Each entry pairs a vanilla Mojang
# disc sprite (chosen by mood color) with one of our 8 custom tracks.
# Resolved by id_from_name at _ready so we don't have to depend on
# Items.gd's load order here; missing files print one warning + the
# tile entity still tracks the disc (silent fallback).
const _TRACKS: Dictionary = {
	"music_disc_first_light": "res://assets/audio/music/First-Light.mp3",
	"music_disc_green_distance": "res://assets/audio/music/Green-Distance.mp3",
	"music_disc_long_shadow": "res://assets/audio/music/Long-Shadow.mp3",
	"music_disc_hollow_earth": "res://assets/audio/music/Hollow-Earth.mp3",
	"music_disc_bedrock": "res://assets/audio/music/Bedrock.mp3",
	"music_disc_open_sky": "res://assets/audio/music/Open-Sky.mp3",
	"music_disc_hearthstone": "res://assets/audio/music/Hearthstone.mp3",
	"music_disc_still_water": "res://assets/audio/music/Still-Water.mp3",
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
# Cached player ref + last music-pause state. Lookup-deferred so we
# don't depend on the player scene being ready at autoload _ready time.
var _cached_player: Node3D = null
var _music_paused_for_jukebox: bool = false
var _audibility_accum: float = 0.0


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
	# Drive the audibility poll. Cheap — `_audibility_tick` is a Vector3
	# distance check per active jukebox, gated to 0.5 s, so the per-frame
	# cost is one float compare + an early return when no jukebox is
	# playing (the dominant case).
	set_process(true)


# Poll the player's distance to every active jukebox every 0.5 s. If
# any is within audible range (= the AudioStreamPlayer3D's
# max_distance, where the falloff curve reaches zero), pause the
# ambient MusicPlayer pool so the disc isn't competing with random
# ambient tracks. Resume when no jukebox is audible.
#
# Vanilla MC doesn't actually do this — discs and ambient music can
# overlap in vanilla — but the overlap reads as a muddy mix on our
# longer tracks (60-180 s vanilla discs vs minute-long ambient tracks
# with similar instrumentation). Pausing matches the player-intent
# "I put a disc on, I want to hear THE disc."
func _process(delta: float) -> void:
	if _players.is_empty():
		# Re-arm the music pool the moment the last jukebox stops. No
		# distance check needed — without active players, nothing is
		# audible by definition.
		if _music_paused_for_jukebox:
			_resume_music()
		return
	_audibility_accum += delta
	if _audibility_accum < 0.5:
		return
	_audibility_accum = 0.0
	_audibility_tick()


func _audibility_tick() -> void:
	var player: Node3D = _get_player()
	if player == null:
		return
	var threshold_sq: float = _MAX_DISTANCE * _MAX_DISTANCE
	var any_audible: bool = false
	for cell_pos: Vector3i in _players.keys():
		var p: AudioStreamPlayer3D = _players[cell_pos] as AudioStreamPlayer3D
		if not is_instance_valid(p):
			continue
		var d_sq: float = p.global_position.distance_squared_to(player.global_position)
		if d_sq <= threshold_sq:
			any_audible = true
			break
	if any_audible and not _music_paused_for_jukebox:
		_pause_music()
	elif not any_audible and _music_paused_for_jukebox:
		_resume_music()


func _pause_music() -> void:
	if Music != null and Music.has_method("set_paused"):
		Music.set_paused(true)
	_music_paused_for_jukebox = true


func _resume_music() -> void:
	if Music != null and Music.has_method("set_paused"):
		Music.set_paused(false)
	_music_paused_for_jukebox = false


func _get_player() -> Node3D:
	if _cached_player != null and is_instance_valid(_cached_player):
		return _cached_player
	# Player lives under Main; cached lookup avoids the find_child walk
	# on every audibility tick. find_child is recursive but bounded by
	# the small Main subtree, so the cold lookup is cheap too.
	var root: Window = get_tree().root
	if root == null:
		return null
	var main: Node = root.get_node_or_null("Main")
	if main == null:
		return null
	_cached_player = main.find_child("Player", true, false) as Node3D
	return _cached_player


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
	# Inline audibility check so the ambient MusicPlayer is paused the
	# instant a disc starts (instead of waiting up to 0.5 s for the next
	# _audibility_tick). Without this, the gap timer could fire and
	# overlay a random ambient track on top of the freshly-started disc.
	var listener: Node3D = _get_player()
	if listener != null:
		var d_sq: float = player.global_position.distance_squared_to(listener.global_position)
		if d_sq <= _MAX_DISTANCE * _MAX_DISTANCE and not _music_paused_for_jukebox:
			_pause_music()


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
