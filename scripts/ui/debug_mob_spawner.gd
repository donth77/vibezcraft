extends Control

# Preloads dodge the class_name registry race (headless tests skip the
# editor scan that populates the global class cache).
const _MOB_REGISTRY: GDScript = preload("res://scripts/entities/mob_registry.gd")
const _MOB_SPAWNER_MGR: GDScript = preload("res://scripts/world/mob_spawner_manager.gd")

# Debug UI for placing vanilla-style mob spawner cages anywhere in the
# world. Companion to DebugItemSpawner (F4); this one is gated by F6.
#
# Pressing F6 opens a panel with one button per registered mob (from
# MobRegistry). Clicking a button:
#   1. Closes the panel
#   2. Places a MOB_SPAWNER cage block ~3 m in front of the player
#   3. Configures the tile entity (MobSpawnerManager) to spawn the
#      selected mob — first tick fires 5-10 s out, then every 10-40 s.
#
# Used as the primary mob-test rig during development. Once natural
# spawning lands (M0 §3.4), this still works as a "I want a specific
# mob right here" tool.

const _ICON_SIZE: int = 64
const _COLUMNS: int = 4

var _player: Node
var _grid: GridContainer
var _prev_mouse_mode: int = Input.MOUSE_MODE_CAPTURED
# When checked, mob buttons spawn ONE mob directly at the floor cell
# instead of placing a vanilla spawner cage block. Useful for testing a
# single mob's AI / animations / damage path without the per-cage spawn
# cooldown + 6-mob cap getting in the way. Default ON in debug mode —
# direct-spawn is the common F6 use case during development; the
# spawner-cage path is only useful when explicitly testing the cage.
var _spawn_single_mode: bool = true


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_PASS
	visible = false
	_player = get_tree().root.get_node_or_null("Main/Player")
	# Full-screen dim scrim — matches DebugItemSpawner styling.
	var scrim := ColorRect.new()
	scrim.anchor_right = 1.0
	scrim.anchor_bottom = 1.0
	scrim.color = Color(0, 0, 0, 0.6)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)
	# Centered panel. Sized between "tiny popup" and the item-spawner's
	# 920x680 — 9 mobs (at full Alpha-mob roster) fit in 3 rows of 4 at
	# ~140px per cell, with room for a 22pt title header.
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -380
	panel.offset_top = -280
	panel.offset_right = 380
	panel.offset_bottom = 280
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.97)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.45, 0.45, 0.48)
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)
	_build_header(vbox)
	_build_grid(vbox)


func _build_header(vbox: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	vbox.add_child(header)
	var title := Label.new()
	title.text = "Mob Spawner  (F6 / Esc to close)"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.pressed.connect(_hide)
	header.add_child(close_btn)
	# Mode toggle — sits on its own row below the title.
	var mode_row := HBoxContainer.new()
	vbox.add_child(mode_row)
	var single_cb := CheckBox.new()
	single_cb.text = "Spawn single mob (skip spawner cage)"
	single_cb.add_theme_font_size_override("font_size", 16)
	single_cb.button_pressed = _spawn_single_mode
	single_cb.toggled.connect(_on_single_mode_toggled)
	mode_row.add_child(single_cb)


func _on_single_mode_toggled(pressed: bool) -> void:
	_spawn_single_mode = pressed


func _build_grid(vbox: VBoxContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = _COLUMNS
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	for name: String in _MOB_REGISTRY.names():
		_grid.add_child(_make_cell(name))


func _make_cell(mob_name: String) -> Button:
	var btn := Button.new()
	var outer_w: int = _ICON_SIZE + 90
	var outer_h: int = _ICON_SIZE + 20
	btn.custom_minimum_size = Vector2(outer_w, outer_h)
	btn.text = mob_name
	btn.tooltip_text = "Spawn a %s mob spawner block" % mob_name
	btn.add_theme_font_size_override("font_size", 18)
	btn.pressed.connect(_on_cell_pressed.bind(mob_name))
	return btn


# Place a spawner block ~3 m in front of the player, sitting ON the
# floor (not floating at head height) and configure it to spawn the
# selected mob. Earlier version put it at player.global_position.y
# which is the player's CENTER (head level) — that left the spawner
# floating 1-2 cells above the actual floor, and the mob-spawn algorithm
# (which needs opaque-below for a valid floor) couldn't find candidates
# in the 4x2x4 spawn box. The downward scan below finds the first
# solid cell and places the spawner one cell above it.
func _on_cell_pressed(mob_name: String) -> void:
	if _player == null:
		return
	var cm: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if cm == null:
		return
	var forward: Vector3 = -_player.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = Vector3(0, 0, -1)
	var dest_world: Vector3 = _player.global_position + forward.normalized() * 3.0
	# Downward scan to find the floor at the player's eye-x/z column.
	# Start from ceil(player.y + 0.5) so we don't miss a floor that's
	# exactly at player feet level, and walk down until we hit a non-AIR
	# cell. The spawner lands one cell above that.
	var scan_x: int = int(floor(dest_world.x))
	var scan_z: int = int(floor(dest_world.z))
	# Scan from sky-top down for the first OPAQUE cell. Starting from
	# the player's Y misses terrain 3 m forward that's HIGHER than the
	# player (looking up a hill). Sky-top start guarantees we find the
	# topmost surface regardless of terrain shape. Also skips
	# non-opaque cells (snow_layer, flowers, etc.) so the spawner ends
	# up on a real floor that the mob-spawn algorithm accepts.
	var scan_y: int = 127  # Chunk.SIZE_Y - 1
	var floor_y: int = -1
	while scan_y > 0:
		var id: int = cm.get_world_block(Vector3i(scan_x, scan_y, scan_z))
		if id != Blocks.AIR and Blocks.is_opaque(id):
			floor_y = scan_y
			break
		scan_y -= 1
	if floor_y < 0:
		push_warning("[debug_mob_spawner] no floor below target cell; refusing")
		return
	var pos := Vector3i(scan_x, floor_y + 1, scan_z)
	if _spawn_single_mode:
		_spawn_one_mob(cm, mob_name, pos)
	else:
		_place_spawner_cage(cm, mob_name, pos)
	_hide()


# Single-mob mode — instantiate one mob at the floor cell, no cage.
# Useful for testing AI / animations / damage without the cage's spawn
# cooldown and 6-mob cap. Centered + tiny y nudge to clear floor face.
func _spawn_one_mob(cm: Node, mob_name: String, pos: Vector3i) -> void:
	var script: Script = _MOB_REGISTRY.script_for(mob_name)
	if script == null:
		push_warning("[debug_mob_spawner] unknown mob '%s'" % mob_name)
		return
	var mob: CharacterBody3D = script.new() as CharacterBody3D
	if mob == null:
		return
	# Slime needs a vanilla-style random size (1, 2, or 4) BEFORE
	# being added to the tree — `_ready()` reads `_size` to compute
	# HP, BB, and visual scale, and it doesn't rebuild if size changes
	# later. Without this nudge, every debug-spawned slime is size 1,
	# which can't damage the player (vanilla `b(EntityHuman)` gates on
	# `c > 1`) — making the mob impossible to playtest.
	if mob_name == "slime" and mob.has_method("setup_size"):
		mob.call("setup_size", 1 << randi_range(0, 2))
	cm.add_child(mob)
	mob.global_position = Vector3(pos) + Vector3(0.5, 0.05, 0.5)


# Spawner-cage mode — place the block + configure tile entity.
# Allows overwriting REPLACEABLE blocks (snow_layer, flowers, etc.) so
# snowy terrain placement matches vanilla place-on-block semantics.
func _place_spawner_cage(cm: Node, mob_name: String, pos: Vector3i) -> void:
	var dest_id: int = cm.get_world_block(pos)
	if dest_id != Blocks.AIR and not Blocks.is_replaceable(dest_id):
		push_warning("[debug_mob_spawner] target cell is occupied; refusing")
		return
	cm.set_world_block(pos, Blocks.MOB_SPAWNER)
	_MOB_SPAWNER_MGR.configure(pos, mob_name)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("open_mob_spawner") and _spawner_available():
		if visible:
			_hide()
		else:
			_show()
		get_viewport().set_input_as_handled()
	elif visible and event.is_action_pressed("pause"):
		_hide()
		get_viewport().set_input_as_handled()


# Same creative-or-debug gate as the item spawner.
func _spawner_available() -> bool:
	if Game.debug_enabled:
		return true
	if _player != null and "creative_mode" in _player and _player.creative_mode:
		return true
	return false


func _show() -> void:
	_prev_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true


func _hide() -> void:
	visible = false
	Input.mouse_mode = _prev_mouse_mode
