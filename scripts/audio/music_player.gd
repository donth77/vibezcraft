extends Node

# Background music system — faithful port of vanilla Alpha 1.2.6's qg.java.
#
# Vanilla behavior (decompiled from qg.c / qg.i):
#   - Initial delay: random 0–12000 ticks (0–600s at 20 tps)
#   - Between tracks: random 12000–24000 ticks (600–1200s)
#   - Random pick from flat pool, no repeat avoidance
#   - Single non-positional source, volume = options music slider
#
# Only active in-game — call start_music() when the world loads,
# stop_music() when returning to main menu.

const _MUSIC_DIR: String = "res://assets/audio/music/"
const _EXTENSIONS: Array[String] = [".mp3", ".ogg"]

const _MIN_GAP_SECS: float = 600.0
const _MAX_GAP_SECS: float = 1200.0
const _INITIAL_MIN_SECS: float = 0.0
const _INITIAL_MAX_SECS: float = 600.0

var _tracks: Array[AudioStream] = []
var _player: AudioStreamPlayer
var _gap_timer: Timer
var _volume_linear: float = 1.0
var _active: bool = false


func _ready() -> void:
	_load_tracks()
	if _tracks.is_empty():
		return
	_player = AudioStreamPlayer.new()
	_player.bus = &"Master"
	_player.finished.connect(_on_track_finished)
	add_child(_player)
	_gap_timer = Timer.new()
	_gap_timer.one_shot = true
	_gap_timer.timeout.connect(_on_gap_timeout)
	add_child(_gap_timer)
	var cfg := SettingsMenu.load_config()
	# Default 0.25 — music sat above ambient/SFX even at 0.5; quartered
	# so a fresh install lands at a comfortable level. User can still
	# crank it back to max via the audio menu.
	_volume_linear = float(cfg.get_value("audio", "music_volume", 0.25))
	_apply_volume()


func start_music() -> void:
	if _active or _tracks.is_empty():
		return
	_active = true
	var initial_delay: float = randf_range(_INITIAL_MIN_SECS, _INITIAL_MAX_SECS)
	_gap_timer.start(initial_delay)


func stop_music() -> void:
	_active = false
	if _gap_timer != null:
		_gap_timer.stop()
	if _player != null:
		_player.stop()
		_player.stream = null


# Pause / resume in-place — used by the death screen so a death-time
# gap-timeout doesn't start a fresh track over the dying-player UI.
# Different from stop_music() which fully tears down for menu return.
func set_paused(paused: bool) -> void:
	if _player != null:
		_player.stream_paused = paused
	if _gap_timer != null:
		_gap_timer.paused = paused


func set_volume(linear: float) -> void:
	_volume_linear = clampf(linear, 0.0, 1.0)
	_apply_volume()


func _apply_volume() -> void:
	if _player == null:
		return
	if _volume_linear <= 0.0:
		_player.volume_db = -80.0
	else:
		_player.volume_db = linear_to_db(_volume_linear)


func _load_tracks() -> void:
	var dir := DirAccess.open(_MUSIC_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var lower: String = file_name.to_lower()
			for ext in _EXTENSIONS:
				if lower.ends_with(ext):
					var stream: AudioStream = load(_MUSIC_DIR + file_name)
					if stream != null:
						_tracks.append(stream)
					break
		file_name = dir.get_next()
	dir.list_dir_end()
	if not _tracks.is_empty():
		print("[Music] loaded %d tracks" % _tracks.size())


func _on_gap_timeout() -> void:
	if not _active or _tracks.is_empty() or _volume_linear <= 0.0:
		if _active:
			_gap_timer.start(randf_range(_MIN_GAP_SECS, _MAX_GAP_SECS))
		return
	var track: AudioStream = _tracks[randi() % _tracks.size()]
	_player.stream = track
	_apply_volume()
	_player.play()


func _on_track_finished() -> void:
	if not _active:
		return
	var gap: float = randf_range(_MIN_GAP_SECS, _MAX_GAP_SECS)
	_gap_timer.start(gap)
