class_name DebugStats
extends PanelContainer

# Top-right perf/world stats panel. Polls every UPDATE_INTERVAL_SEC so we
# don't churn the label every frame. Visibility tracks Game.debug_enabled.

const UPDATE_INTERVAL_SEC: float = 0.25
const _FONT_SIZE: int = 36
const _PERF_FONT_SIZE: int = 18

var _player: Node3D
var _chunk_manager: Node
var _label: Label
var _perf_label: Label
var _copy_button: Button
var _copied_flash: float = 0.0  # seconds remaining for "Copied!" label
var _accum: float = 0.0
# F3 toggles this. Independent of Game.debug_enabled so the panel is
# available on demand without flipping the broader debug mode (creative,
# hotbar fill, etc.).
var _panel_shown: bool = false


func _ready() -> void:
	# PASS so the Copy button inside still receives clicks once the player
	# has released the mouse (Esc). Label + scroll child are IGNORE, the
	# Button defaults to STOP on its own hit rect.
	mouse_filter = Control.MOUSE_FILTER_PASS
	# Anchor top-right, auto-sizing: let the container shrink to content.
	# No offset_bottom — PanelContainer hugs its VBox child and the VBox's
	# internal caps keep the whole panel on-screen.
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 0.0
	offset_left = -440
	offset_top = 56
	offset_right = -16
	offset_bottom = 56  # container will expand downward as needed
	size_flags_horizontal = Control.SIZE_SHRINK_END
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.06, 0.78)
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	# Main stats — large font.
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_font_size_override("font_size", _FONT_SIZE)
	_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.95, 1.0))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_label.add_theme_constant_override("outline_size", 3)
	_label.text = ""
	vbox.add_child(_label)

	# Perf probes — tiny font so they never blow out the panel height.
	_perf_label = Label.new()
	_perf_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_perf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_perf_label.add_theme_font_size_override("font_size", _PERF_FONT_SIZE)
	_perf_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0, 1.0))
	_perf_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_perf_label.add_theme_constant_override("outline_size", 2)
	_perf_label.text = ""
	vbox.add_child(_perf_label)

	_copy_button = Button.new()
	_copy_button.text = "Copy stats"
	_copy_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	_copy_button.add_theme_font_size_override("font_size", 20)
	_copy_button.pressed.connect(_on_copy_pressed)
	vbox.add_child(_copy_button)

	_player = get_tree().root.get_node_or_null("Main/Player") as Node3D
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")


func _on_copy_pressed() -> void:
	var payload := _format_stats()
	var perf := _format_perf()
	if perf != "":
		payload += "\n\n" + perf
	payload += "\n\n--- PerfProbe raw snapshot ---\n"
	payload += str(PerfProbe.snapshot())
	DisplayServer.clipboard_set(payload)
	_copied_flash = 1.2
	_copy_button.text = "Copied!"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_stats_toggle"):
		_panel_shown = not _panel_shown
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_stats_copy") and _panel_shown:
		_on_copy_pressed()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	visible = _panel_shown
	if not visible:
		return
	if _copied_flash > 0.0:
		_copied_flash -= delta
		if _copied_flash <= 0.0 and _copy_button != null:
			_copy_button.text = "Copy stats"
	_accum += delta
	if _accum < UPDATE_INTERVAL_SEC:
		return
	_accum = 0.0
	if _label != null:
		_label.text = _format_stats()
	if _perf_label != null:
		_perf_label.text = _format_perf()


func _format_stats() -> String:
	var lines: Array[String] = []
	lines.append("FPS: %d" % Engine.get_frames_per_second())
	if _chunk_manager != null:
		var chunks_dict: Dictionary = _chunk_manager.get("_chunks")
		var pending_dict: Dictionary = _chunk_manager.get("_pending")
		var loaded: int = chunks_dict.size() if chunks_dict != null else 0
		var pending: int = pending_dict.size() if pending_dict != null else 0
		var total: int = int(_chunk_manager.get("chunks_generated_total"))
		var saved_dict: Dictionary = _chunk_manager.get("_saved_chunks")
		var saved: int = saved_dict.size() if saved_dict != null else 0
		# Sum the actual compressed byte sizes — gives a real measurement
		# instead of the worst-case 32 KB per chunk number.
		var saved_bytes: int = 0
		if saved_dict != null:
			for k in saved_dict:
				saved_bytes += (saved_dict[k].bytes as PackedByteArray).size()
		lines.append("Chunks: %d (+%d pending)" % [loaded, pending])
		lines.append("Generated: %d total" % total)
		lines.append("Saved: %d (%.1f KB)" % [saved, float(saved_bytes) / 1024.0])
		lines.append("Blocks: %s" % _humanize(loaded * 32768))
	if _player != null:
		var p: Vector3 = _player.global_position
		lines.append("Pos: %.1f, %.1f, %.1f" % [p.x, p.y, p.z])
		lines.append("Block: %d, %d, %d" % [int(floor(p.x)), int(floor(p.y)), int(floor(p.z))])
	var mem_mb: float = float(OS.get_static_memory_usage()) / 1048576.0
	lines.append("Mem: %.1f MB" % mem_mb)
	return "\n".join(lines)


# PerfProbe p50/p95 (in µs) per instrumented site. Shown in a small font
# so it doesn't push the panel off-screen. Empty until the game has run
# long enough to record samples.
func _format_perf() -> String:
	var snap: Dictionary = PerfProbe.snapshot()
	if snap.is_empty():
		return ""
	var lines: Array[String] = ["Perf p50/p95 µs:"]
	var keys: Array = snap.keys()
	keys.sort()
	for probe_label: String in keys:
		var e: Dictionary = snap[probe_label]
		lines.append("  %s: %d / %d (n=%d)" % [probe_label, e.p50, e.p95, e.count])
	return "\n".join(lines)


# Compact thousands separator: 32768 → "32.8k", 1000000 → "1.0M".
func _humanize(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)
