class_name DebugStats
extends PanelContainer

# Top-right perf/world stats panel. Polls every UPDATE_INTERVAL_SEC so we
# don't churn the label every frame. Visibility tracks Game.debug_enabled.

const UPDATE_INTERVAL_SEC: float = 0.25
const _FONT_SIZE: int = 36

var _player: Node3D
var _chunk_manager: Node
var _label: Label
var _accum: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchor top-right; PanelContainer hugs its child Label tightly, so we
	# don't pre-size width — let the panel shrink to fit the longest line
	# plus the styling margins.
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 0.0
	offset_left = -440
	offset_top = 56
	offset_right = -16
	offset_bottom = 56 + 44 * 9  # ~9 lines of 44px
	size_flags_horizontal = Control.SIZE_SHRINK_END

	# Faded solid background only — no border per user feedback.
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

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_font_size_override("font_size", _FONT_SIZE)
	_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.95, 1.0))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_label.add_theme_constant_override("outline_size", 3)
	_label.text = ""
	add_child(_label)

	_player = get_tree().root.get_node_or_null("Main/Player") as Node3D
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")


func _process(delta: float) -> void:
	visible = Game.debug_enabled
	if not visible:
		return
	_accum += delta
	if _accum < UPDATE_INTERVAL_SEC:
		return
	_accum = 0.0
	if _label != null:
		_label.text = _format_stats()


func _format_stats() -> String:
	var lines: Array[String] = []
	lines.append("FPS: %d" % Engine.get_frames_per_second())
	if _chunk_manager != null:
		var chunks_dict: Dictionary = _chunk_manager.get("_chunks")
		var pending_dict: Dictionary = _chunk_manager.get("_pending")
		var loaded: int = chunks_dict.size() if chunks_dict != null else 0
		var pending: int = pending_dict.size() if pending_dict != null else 0
		var total: int = int(_chunk_manager.get("chunks_generated_total"))
		var modified_dict: Dictionary = _chunk_manager.get("_modified_chunks")
		var saved: int = modified_dict.size() if modified_dict != null else 0
		# Each chunk is 16 × 128 × 16 = 32768 blocks (air included). Saved
		# chunks each cost ~32 KB of memory (block PackedByteArray).
		lines.append("Chunks: %d (+%d pending)" % [loaded, pending])
		lines.append("Generated: %d total" % total)
		lines.append("Saved: %d (%.1f MB)" % [saved, float(saved * 32768) / 1048576.0])
		lines.append("Blocks: %s" % _humanize(loaded * 32768))
	if _player != null:
		var p: Vector3 = _player.global_position
		lines.append("Pos: %.1f, %.1f, %.1f" % [p.x, p.y, p.z])
		lines.append("Block: %d, %d, %d" % [int(floor(p.x)), int(floor(p.y)), int(floor(p.z))])
	var mem_mb: float = float(OS.get_static_memory_usage()) / 1048576.0
	lines.append("Mem: %.1f MB" % mem_mb)
	return "\n".join(lines)


# Compact thousands separator: 32768 → "32.8k", 1000000 → "1.0M".
func _humanize(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)
