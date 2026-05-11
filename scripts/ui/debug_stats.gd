class_name DebugStats
extends PanelContainer

# Top-right perf/world stats panel. Polls every UPDATE_INTERVAL_SEC so we
# don't churn the label every frame. Visibility tracks Game.debug_enabled.

const UPDATE_INTERVAL_SEC: float = 0.25
const _FONT_SIZE: int = 36
const _PERF_FONT_SIZE: int = 18
# Cave scout is a 9-chunk × 16×16×54-cell scan (~225K get_block_unchecked
# calls ≈ 10-15 ms on the main thread). Auto-refresh even at 2 s interval
# was still stacking onto dig-frames that already eat 90-260 ms for the
# chunk re-mesh, producing visible hitches. Now the scout only runs when
# the user asks for it (F6 keybind or the "Refresh scout" button below
# the panel), and the result stays pinned until the next explicit refresh.

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
# Cached cave-scout output. Empty until the user asks for a refresh.
var _scout_cache: Dictionary = {}
var _scout_button: Button
# Chunk-shader light-heatmap mode, cycled by F8.
#   0 = normal, 1 = sky_light, 2 = block_light, 3 = combined
var _light_view: int = 0


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
	offset_left = -560
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
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	_label.add_theme_constant_override("shadow_offset_x", 2)
	_label.add_theme_constant_override("shadow_offset_y", 2)
	_label.text = ""
	vbox.add_child(_label)

	# Perf probes — tiny font so they never blow out the panel height.
	_perf_label = Label.new()
	_perf_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_perf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_perf_label.add_theme_font_size_override("font_size", _PERF_FONT_SIZE)
	_perf_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0, 1.0))
	_perf_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	_perf_label.add_theme_constant_override("shadow_offset_x", 1)
	_perf_label.add_theme_constant_override("shadow_offset_y", 1)
	_perf_label.text = ""
	vbox.add_child(_perf_label)

	_scout_button = Button.new()
	_scout_button.text = "Refresh scout (F6)"
	_scout_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	_scout_button.add_theme_font_size_override("font_size", 20)
	_scout_button.pressed.connect(_on_scout_pressed)
	vbox.add_child(_scout_button)

	_copy_button = Button.new()
	_copy_button.text = "Copy stats (F12)"
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
	elif event.is_action_pressed("debug_stats_scout") and _panel_shown:
		_on_scout_pressed()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_stats_reset_perf") and _panel_shown:
		# Wipe the perf-probe ring so the next window of measurements
		# isolates whatever the user is doing right now (e.g. "walk for
		# 5 seconds, see what spiked"). Without this, persistent maxes
		# from boot / chunk-rush stay in the snapshot forever.
		PerfProbe.reset()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("debug_lighting_view"):
		_light_view = (_light_view + 1) % 4
		var mat: ShaderMaterial = BlockAtlas.material()
		mat.set_shader_parameter("debug_view", _light_view)
		var label: String = ["normal", "sky_light", "block_light", "combined"][_light_view]
		print("[debug] chunk light heatmap = %d (%s)" % [_light_view, label])
		get_viewport().set_input_as_handled()


func _on_scout_pressed() -> void:
	_scout_cache = _scout_chunks_around_player()
	if _perf_label != null:
		_perf_label.text = _format_perf()


func _process(delta: float) -> void:
	visible = _panel_shown
	if not visible:
		return
	if _copied_flash > 0.0:
		_copied_flash -= delta
		if _copied_flash <= 0.0 and _copy_button != null:
			_copy_button.text = "Copy stats (F12)"
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
		# Biome readout — only meaningful in 3D-density mode (2D path
		# has no biome system). Shows climate values (temp, rain) plus
		# the selected biome name from gg.java's decision tree.
		var mode: String = "3D" if Worldgen.terrain_3d_enabled else "2D"
		lines.append("Terrain: %s" % mode)
		if Worldgen.terrain_3d_enabled:
			var climate: Vector2 = Worldgen3D.climate_at(p.x, p.z)
			var biome_id: int = Worldgen3D.biome_at(p.x, p.z)
			var biome_name: String = Worldgen3D.Biome.keys()[biome_id]
			lines.append(
				"Biome: %s  T=%.2f R=%.2f" % [biome_name.capitalize(), climate.x, climate.y]
			)
	var mem_mb: float = float(OS.get_static_memory_usage()) / 1048576.0
	lines.append("Mem: %.1f MB" % mem_mb)
	return "\n".join(lines)


# Scans the 3×3 chunks around the player for cave-indicator cells.
# Counts AIR below the per-column heightmap (cave air), LAVA cells, and
# reports the nearest lava position. 3×3 coverage (~256 × 256 blocks)
# buys us enough area that a lucky empty chunk doesn't read as "no caves
# anywhere." Returns an empty dict if the chunk manager isn't reachable.
func _scout_chunks_around_player() -> Dictionary:
	if _chunk_manager == null:
		return {}
	var chunks_dict: Dictionary = _chunk_manager.get("_chunks")
	if chunks_dict == null:
		return {}
	var p: Vector3 = _player.global_position
	var pcx: int = int(floor(p.x / 16.0))
	var pcz: int = int(floor(p.z / 16.0))
	var pix: int = int(floor(p.x))
	var piy: int = int(floor(p.y))
	var piz: int = int(floor(p.z))
	var subsurf_air: int = 0
	var deep_air: int = 0
	var lava_cells: int = 0
	var nearest_lava_dist_sq: int = 1 << 30
	var nearest_lava: Vector3i = Vector3i(0, 0, 0)
	var chunks_scanned: int = 0
	var chunks_with_caves: int = 0
	for dcx in range(-1, 2):
		for dcz in range(-1, 2):
			var key := Vector2i(pcx + dcx, pcz + dcz)
			if not chunks_dict.has(key):
				continue
			var node = chunks_dict[key]
			if node == null or not ("chunk" in node):
				continue
			var chunk: Chunk = node.chunk
			if chunk == null:
				continue
			chunks_scanned += 1
			var chunk_cave_hits: int = 0
			# Fixed underground band — sea level (64) minus a 9-cell
			# margin. Anything in [1, 55] is "definitely underground" and
			# AIR there is cave air. Avoids a per-column heightmap walk
			# that was the bulk of the 9-chunk scan's cost.
			for y in range(1, 55):
				for z in range(Chunk.SIZE_Z):
					for x in range(Chunk.SIZE_X):
						var id: int = chunk.get_block_unchecked(x, y, z)
						if id == Blocks.AIR:
							subsurf_air += 1
							chunk_cave_hits += 1
							if y < 10:
								deep_air += 1
						elif id == Blocks.LAVA_STILL or id == Blocks.LAVA_FLOWING:
							lava_cells += 1
							var wx: int = (pcx + dcx) * 16 + x
							var wz: int = (pcz + dcz) * 16 + z
							var dx: int = wx - pix
							var dz: int = wz - piz
							var dy: int = y - piy
							var d2: int = dx * dx + dy * dy + dz * dz
							if d2 < nearest_lava_dist_sq:
								nearest_lava_dist_sq = d2
								nearest_lava = Vector3i(wx, y, wz)
			if chunk_cave_hits > 0:
				chunks_with_caves += 1
	var nearest_lava_str := ""
	if lava_cells > 0:
		nearest_lava_str = (
			"(%d,%d,%d) d=%.1f"
			% [
				nearest_lava.x,
				nearest_lava.y,
				nearest_lava.z,
				sqrt(float(nearest_lava_dist_sq)),
			]
		)
	# Biome distribution scan — sample 9×9 chunks (~144×144 blocks)
	# centered on player. Reports counts per biome so you can verify
	# whether the climate noise is producing variety or clustering.
	# Only meaningful in 3D-density mode (2D path doesn't run biome
	# selection); skipped otherwise to keep the readout uncluttered.
	var biome_counts: Dictionary = {}
	if Worldgen.terrain_3d_enabled:
		for cdx in range(-4, 5):
			for cdz in range(-4, 5):
				var wx: float = float((pcx + cdx) * 16 + 8)
				var wz: float = float((pcz + cdz) * 16 + 8)
				var bid: int = Worldgen3D.biome_at(wx, wz)
				biome_counts[bid] = int(biome_counts.get(bid, 0)) + 1
	return {
		"subsurf_air": subsurf_air,
		"deep_air": deep_air,
		"lava_cells": lava_cells,
		"nearest_lava": nearest_lava_str,
		"chunks_scanned": chunks_scanned,
		"chunks_with_caves": chunks_with_caves,
		"biome_counts": biome_counts,
	}


# PerfProbe p50/p95 (in µs) per instrumented site. Shown in a small font
# so it doesn't push the panel off-screen. Empty until the game has run
# long enough to record samples.
func _format_perf() -> String:
	var lines: Array[String] = []
	# Cave scouting — manual refresh only (F6 or the "Refresh scout"
	# button). Auto-refresh was stacking onto the dig re-mesh and causing
	# visible frame hitches; the user asks for a fresh number when they
	# want one.
	if _scout_cache.is_empty():
		lines.append("Scout: press F6 to scan 3×3 chunks for caves/lava")
	elif _player != null:
		var scout: Dictionary = _scout_cache
		if not scout.is_empty():
			lines.append(
				(
					"Scout (3×3 chunks): cave-air=%d lava=%d (y<10 air=%d)"
					% [scout.subsurf_air, scout.lava_cells, scout.deep_air]
				)
			)
			if scout.nearest_lava != "":
				lines.append("  nearest lava: %s" % scout.nearest_lava)
			if scout.chunks_with_caves > 0:
				lines.append(
					(
						"  %d/%d scanned chunks have caves"
						% [scout.chunks_with_caves, scout.chunks_scanned]
					)
				)
			var bcounts: Dictionary = scout.get("biome_counts", {})
			if not bcounts.is_empty():
				var sorted_ids: Array = bcounts.keys()
				sorted_ids.sort_custom(func(a, b): return bcounts[a] > bcounts[b])
				var parts: Array[String] = []
				for bid: int in sorted_ids:
					var bname: String = Worldgen3D.Biome.keys()[bid].capitalize()
					parts.append("%s=%d" % [bname, bcounts[bid]])
				lines.append("Biomes (9×9 chunks): %s" % " ".join(parts))
	var snap: Dictionary = PerfProbe.snapshot()
	if not snap.is_empty():
		# p50/p95/max — max catches the lag spike that p95 averages away.
		# 1 frame at 90 fps = 11111 µs. Anything > 5000 µs (5 ms) on a
		# main-thread probe will visibly hitch.
		lines.append("Perf p50/p95/max µs:  (F7=reset)")
		var keys: Array = snap.keys()
		keys.sort()
		for probe_label: String in keys:
			var e: Dictionary = snap[probe_label]
			lines.append("  %s: %d / %d / %d (n=%d)" % [probe_label, e.p50, e.p95, e.max, e.count])
	return "\n".join(lines)


# Compact thousands separator: 32768 → "32.8k", 1000000 → "1.0M".
func _humanize(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)
