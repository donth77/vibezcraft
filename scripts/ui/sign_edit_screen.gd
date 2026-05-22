class_name SignEditScreen
extends Control

# Vanilla MC Alpha 1.2.6 GuiEditSign (pv.java). Faithful port of the
# original layout:
#   * Standard dim-screen background (drawDefaultBackground equivalent),
#     no extra dark pane around the dialog
#   * Title "Edit sign message:" near the top, white
#   * Live 3D model of the sign at screen center showing the player's
#     text as they type, NOT continuously rotating (vanilla rotates by
#     the sign's actual placed yaw via glRotatef(meta * 22.5°); we just
#     show it face-on since the editor's job is letting the player read
#     what they're typing)
#   * Single "Done" button at the bottom
#
# Key handling (matches pv.java::a(char, int)):
#   Up arrow    → prev line  (this.j = this.j - 1 & 3)
#   Down arrow  → next line  (this.j = this.j + 1 & 3)
#   Enter       → next line  (vanilla treats Down + Enter identically)
#   Backspace   → delete last char on active line if non-empty
#   Printable   → append if line < 15 chars
#   Esc         → close (bp base behavior; text already in tile entity)
#
# Vanilla saves per keystroke into TileEntitySign.a[i]; we batch save
# all 4 lines on close (Esc or Done). Visible behaviour is identical —
# the in-world SignNode listens to SignStorage.text_changed and only
# refreshes when the editor commits.

const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

# Vanilla qc.java caps lines at 15 chars (FontRenderer width check
# rejects keystrokes that would push the line over). We enforce the
# same hard cap here so SignStorage doesn't need to clip again.
const MAX_CHARS_PER_LINE: int = 15

# Active-line marker — vanilla jx.java line 55 wraps the active line
# as `"> " + text + " <"`. We render the chevrons as separate Label3Ds
# (not part of the text label) so the line text itself never has to
# re-rasterize each blink, which was visibly janky.
# Vanilla pv.java blink rate: `if (this.i / 6 % 2 == 0)`. At 20 TPS
# that's 6/20 = 0.3 s on then 0.3 s off (12-tick period).
const CHEVRON_BLINK_PERIOD: float = 0.3

# Per-element scale ratios — all sizes are computed off the current
# viewport rect so the editor scales with the user's resolution setting.
# Values picked so 1920×1080 produces a comfortable layout.
const PREVIEW_WIDTH_RATIO: float = 0.46  # ≈ 880 px at 1920w
const PREVIEW_HEIGHT_RATIO: float = 0.41  # ≈ 440 px at 1080h
const TITLE_SIZE_RATIO: float = 0.037  # ≈ 40 px at 1080h (was 56 — too loud)
const DONE_WIDTH_RATIO: float = 0.167  # ≈ 320 px at 1920w
const DONE_HEIGHT_RATIO: float = 0.067  # ≈ 72 px at 1080h
const DONE_FONT_RATIO: float = 0.026  # ≈ 28 px at 1080h
const VBOX_SEPARATION_RATIO: float = 0.030  # ≈ 32 px at 1080h
# Minimum sizes — if someone runs at 640×360 we don't want the preview
# collapsing to a postage stamp. Floors below this.
const MIN_PREVIEW_SIZE: Vector2 = Vector2(420, 200)
const MIN_TITLE_FONT: int = 24
const MIN_DONE_FONT: int = 16

var _lines: PackedStringArray = PackedStringArray(["", "", "", ""])
var _active_line: int = 0
var _target_pos: Vector3i = Vector3i.ZERO
var _is_open: bool = false
var _prev_mouse_mode: int = Input.MOUSE_MODE_CAPTURED
# 4 Label3D children inside the SubViewport — show the player's text
# painted on the preview sign mesh. Replaces the 2D line labels the
# old planks-panel preview used.
var _preview_text_labels: Array[Label3D] = []
# References kept so _resize_for_viewport can update them when the
# window size changes at runtime.
var _preview_container: SubViewportContainer
var _preview_viewport: SubViewport
var _title_label: Label
var _done_button: Button
var _vbox: VBoxContainer
# Active-line chevrons — separate Label3D pair (one ">" + one "<")
# whose visibility toggles for the blink. Keeping them OUTSIDE the
# line text labels means the text labels never re-rasterize on each
# blink, so the inputted glyphs stay rock-steady. Positioned per
# active line in _position_chevrons.
var _chevron_left: Label3D
var _chevron_right: Label3D
# Chevron blink state — toggled in _process. Active line shows the
# chevrons when true, hidden when false.
var _chevrons_visible: bool = true
var _chevron_blink_accum: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	# Explicitly enable unhandled key input — Godot 4 turns this off
	# automatically when a Control script overrides _unhandled_key_input,
	# but only if the override was defined at parse time; if we toggle
	# visibility before any key arrives, the flag can flip off. Set it
	# explicitly so typing always reaches us.
	set_process_unhandled_key_input(true)
	# drawDefaultBackground equivalent — dim the whole screen behind the
	# dialog. Kept light (0.2) so the UI elements + preview composited
	# on top read brightly. Higher alphas (0.45+) make the empty
	# transparent space around the SubViewport's sign mesh show the dim
	# through and the whole preview area reads as a dark pane.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.2)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	# Centered vertical stack of title + preview + Done button.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var font: Font = load(FONT_PATH) as Font
	_vbox = VBoxContainer.new()
	_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(_vbox)
	# Title — vanilla pv.java line 13: `protected String a = "Edit sign message:";`
	_title_label = Label.new()
	_title_label.text = "Edit sign message:"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if font != null:
		_title_label.add_theme_font_override("font", font)
	_title_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_title_label.add_theme_constant_override("shadow_offset_x", 3)
	_title_label.add_theme_constant_override("shadow_offset_y", 3)
	_vbox.add_child(_title_label)
	# 3D sign preview — face-on, no rotation. Text updates live as the
	# player types.
	var preview := _build_preview_panel(font)
	_vbox.add_child(preview)
	# Done button — vanilla pv.java line 25:
	#   `this.e.add(new gh(0, this.c / 2 - 100, this.d / 4 + 120, "Done"));`
	# Styled to match VanillaButton (same colour palette + flat panel
	# from vendor/alpha-1.2.6-src/src/gh.java) instead of Godot's default
	# dark button, so it reads bright on the dim backdrop.
	_done_button = Button.new()
	_done_button.text = "Done"
	if font != null:
		_done_button.add_theme_font_override("font", font)
	_style_done_button(_done_button)
	# Vanilla "random.click" — same SFX every button in vanilla MC plays
	# on activation. SFX.play_click already wired by VanillaButton; we
	# call it explicitly since we're not inheriting.
	_done_button.pressed.connect(SFX.play_click)
	_done_button.pressed.connect(_save_and_close)
	var done_holder := CenterContainer.new()
	done_holder.add_child(_done_button)
	_vbox.add_child(done_holder)
	# Compute initial sizes from the current viewport, then keep them in
	# sync if the window resizes while the editor is open.
	_resize_for_viewport()
	var root_vp: Viewport = get_viewport()
	if root_vp != null:
		root_vp.size_changed.connect(_resize_for_viewport)


# Recompute the size of every fixed-pixel piece based on the current
# viewport size. Called on _ready and again whenever the window resizes
# so the editor scales with the user's resolution setting instead of
# being pinned to a single layout.
func _resize_for_viewport() -> void:
	var root_vp: Viewport = get_viewport()
	if root_vp == null:
		return
	var sz: Vector2 = root_vp.get_visible_rect().size
	# Preview viewport + container both get the same display size so the
	# SubViewport renders 1:1 with what's shown (no scaling smear).
	if _preview_container != null and _preview_viewport != null:
		var pw: int = maxi(int(sz.x * PREVIEW_WIDTH_RATIO), int(MIN_PREVIEW_SIZE.x))
		var ph: int = maxi(int(sz.y * PREVIEW_HEIGHT_RATIO), int(MIN_PREVIEW_SIZE.y))
		_preview_container.custom_minimum_size = Vector2(pw, ph)
		_preview_viewport.size = Vector2i(pw, ph)
	if _title_label != null:
		_title_label.add_theme_font_size_override(
			"font_size", maxi(int(sz.y * TITLE_SIZE_RATIO), MIN_TITLE_FONT)
		)
	if _done_button != null:
		var dw: int = maxi(int(sz.x * DONE_WIDTH_RATIO), 200)
		var dh: int = maxi(int(sz.y * DONE_HEIGHT_RATIO), 40)
		_done_button.custom_minimum_size = Vector2(dw, dh)
		_done_button.add_theme_font_size_override(
			"font_size", maxi(int(sz.y * DONE_FONT_RATIO), MIN_DONE_FONT)
		)
	if _vbox != null:
		_vbox.add_theme_constant_override("separation", maxi(int(sz.y * VBOX_SEPARATION_RATIO), 16))


# Build the live 3D preview — a SubViewport rendering a sign mesh
# (post + panel using planks texture + 4 text labels) that rotates
# slowly around its Y axis. The text labels mirror what the player is
# typing, so the preview is also the primary feedback surface.
func _build_preview_panel(font: Font) -> Control:
	_preview_container = SubViewportContainer.new()
	_preview_container.stretch = true
	# Initial sizing placeholder — _resize_for_viewport overrides at the
	# end of _ready and on window resize.
	_preview_container.custom_minimum_size = MIN_PREVIEW_SIZE
	# NEAREST end-of-pipeline filter so the SubViewport's rendered
	# texture (which already has pixel-perfect Label3Ds inside) doesn't
	# get smeared as the container scales it to its layout rect.
	_preview_container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview_viewport = SubViewport.new()
	_preview_viewport.size = Vector2i(MIN_PREVIEW_SIZE)
	_preview_viewport.disable_3d = false
	# TRANSPARENT background — the SubViewport composites over the
	# dim-screen ColorRect, so the sign appears to sit on the dim
	# backdrop with no extra pane around it (vanilla behaviour: the
	# 3D sign is drawn ON TOP of the 2D dim screen).
	_preview_viewport.transparent_bg = true
	# Use a private World3D so the preview camera sees ONLY the post +
	# panel + labels we add below. Without this the SubViewport shares
	# the main scene's World3D and the preview camera renders the loaded
	# chunks behind the sign — stone + bedrock smearing the backdrop.
	_preview_viewport.own_world_3d = true
	# Don't intercept keyboard input internally — let it flow through to
	# the outer SignEditScreen._unhandled_key_input handler so typing
	# works while the player is hovering the preview.
	_preview_viewport.handle_input_locally = false
	# Render every frame so text edits update smoothly.
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_container.add_child(_preview_viewport)
	# Ambient-only environment — no background colour (transparent_bg
	# overrides it), just soft white ambient so the planks aren't black
	# on their unlit faces.
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.7
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_preview_viewport.add_child(world_env)
	# Camera framed so the full panel + post fill the viewport with
	# margin. 1.6 m back at fov 32° → visible height ≈ 0.92 m, slight
	# overshoot of the 1 m sign so 4 text lines all have headroom.
	var cam := Camera3D.new()
	cam.position = Vector3(0, -0.18, 1.6)
	cam.fov = 32.0
	_preview_viewport.add_child(cam)
	# Soft key light from front-above so the planks read warmly.
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-25), deg_to_rad(30), 0)
	light.light_energy = 0.8
	_preview_viewport.add_child(light)
	# Sign root — static, no rotation. Holds the post + panel + labels.
	var root := Node3D.new()
	_preview_viewport.add_child(root)
	# Sign mesh: post + panel with planks texture. Coordinates centered
	# on panel mid (root origin = panel mid) to match the in-world
	# layout SignNode uses.
	var wood_mat: StandardMaterial3D = _wood_material()
	# Post: 0.125 × 0.5 × 0.125, sits below panel.
	var post := MeshInstance3D.new()
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.125, 0.5, 0.125)
	post.mesh = post_mesh
	post.position = Vector3(0, -0.5, 0)
	post.material_override = wood_mat
	root.add_child(post)
	# Panel: 0.875 × 0.5 × 0.125, centered on root origin.
	var panel := MeshInstance3D.new()
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(0.875, 0.5, 0.125)
	panel.mesh = panel_mesh
	panel.material_override = wood_mat
	root.add_child(panel)
	# 4 Label3Ds stacked symmetrically on the panel front face. Use the
	# SAME font_size + pixel_size + LINE_HEIGHT as SignNode so the
	# preview text reads identically to the in-world sign — what you
	# see in the editor is what gets painted on the placed sign.
	var face_offset: float = 0.0625 + 0.01  # panel half-thickness + epsilon
	for i in range(4):
		var label := Label3D.new()
		label.text = ""
		label.font = font
		label.font_size = SignNode.FONT_SIZE
		label.pixel_size = SignNode.TEXT_PIXEL_SIZE
		label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		label.modulate = Color.BLACK
		label.outline_modulate = Color(0, 0, 0, 0)
		label.shaded = false
		label.double_sided = true
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# Preview panel is centered at root y=0. With the texture NOT
		# V-flipped (so its image row 0 — a light pixel — sits at the
		# panel top), the plank-row centers are at panel y = 0.21875,
		# 0.09375, -0.03125, -0.15625 (image y = 1, 5, 9, 13). Apply
		# the wall sign's half-texel shift (+0.015625) so line 0 sits
		# half a texel below plank center 1 — same vertical position
		# as the in-world wall sign, with a small top gap from the
		# panel edge.
		var y: float = (1.5 - float(i)) * SignNode.LINE_HEIGHT + 0.015625
		label.position = Vector3(0, y, face_offset)
		root.add_child(label)
		_preview_text_labels.append(label)
	# Chevron labels — separate Label3Ds positioned next to the active
	# line in _position_chevrons. Visibility toggles for the blink so
	# the text labels never have to re-rasterize.
	_chevron_left = _make_chevron_label(font, ">")
	_chevron_right = _make_chevron_label(font, "<")
	root.add_child(_chevron_left)
	root.add_child(_chevron_right)
	return _preview_container


# Build a single chevron Label3D matched to the text label style.
func _make_chevron_label(font: Font, glyph: String) -> Label3D:
	var label := Label3D.new()
	label.text = glyph
	label.font = font
	label.font_size = SignNode.FONT_SIZE
	label.pixel_size = SignNode.TEXT_PIXEL_SIZE
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	label.modulate = Color.BLACK
	label.outline_modulate = Color(0, 0, 0, 0)
	label.shaded = false
	label.double_sided = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


# Vanilla Alpha button palette + flat panel (gh.java reference), inlined
# instead of using the VanillaButton class so we can keep dynamic
# resolution-based sizing.
func _style_done_button(button: Button) -> void:
	const COLOR_NORMAL: Color = Color(0xE0 / 255.0, 0xE0 / 255.0, 0xE0 / 255.0)
	const COLOR_HOVER: Color = Color(0xFF / 255.0, 0xFF / 255.0, 0xA0 / 255.0)
	const PANEL_FILL: Color = Color(0x6C / 255.0, 0x6C / 255.0, 0x6C / 255.0)
	const PANEL_FILL_HOVER: Color = Color(0x8B / 255.0, 0x8F / 255.0, 0x9C / 255.0)
	const PANEL_BORDER: Color = Color.BLACK
	button.add_theme_color_override("font_color", COLOR_NORMAL)
	button.add_theme_color_override("font_hover_color", COLOR_HOVER)
	button.add_theme_color_override("font_pressed_color", COLOR_HOVER)
	button.add_theme_color_override("font_shadow_color", Color.BLACK)
	button.add_theme_constant_override("shadow_offset_x", 2)
	button.add_theme_constant_override("shadow_offset_y", 2)
	button.add_theme_stylebox_override("normal", _flat_panel(PANEL_FILL, PANEL_BORDER))
	button.add_theme_stylebox_override("hover", _flat_panel(PANEL_FILL_HOVER, PANEL_BORDER))
	button.add_theme_stylebox_override("pressed", _flat_panel(PANEL_FILL_HOVER, PANEL_BORDER))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


static func _flat_panel(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = border
	return sb


# Planks material matched to the in-world chunk shader so the preview
# wood reads identical to the placed sign.
#
# Chunk shader (shaders/chunk.gdshader) is unshaded + bakes the per-face
# Notch brightness × cell light into ALBEDO. For a fully-lit standing
# sign the panel front face (±Z normal) renders at Notch factor 0.6 ×
# light 1.0 = 0.6. Mirror that here: SHADING_MODE_UNSHADED + albedo
# 0.6 so the planks are exactly the same tone as a placed sign on a
# well-lit cell. Editor dim overlay reduced to 0.2 so the resulting
# 0.6 wood still reads brightly enough.
func _wood_material() -> StandardMaterial3D:
	var planks_path: String = (
		"res://assets/textures/blocks/packs/%s/planks.png" % BlockAtlas.active_pack
	)
	var planks_tex: Texture2D = load(planks_path) as Texture2D
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.6, 0.6, 0.6)
	if planks_tex != null:
		# Default BoxMesh UV puts image top at panel top, which is the
		# light pixel row 1 (no seam). Earlier attempts to V-flip so this
		# matched the standing-sign in-world mesher (which DOES V-flip,
		# putting the dark seam at image y=15 on top) made the preview's
		# panel top a dark line. We choose "preview reads cleanly" over
		# "preview exactly mirrors standing in-world wood orientation" —
		# plank rows look symmetric enough that the orientation mismatch
		# isn't noticeable except for the seam-at-top, which IS.
		mat.albedo_texture = planks_tex
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		mat.albedo_color = Color(0.55, 0.36, 0.20) * 0.6
	return mat


# Public entry — called by interaction.gd after placement / right-click.
func open(pos: Vector3i) -> void:
	_target_pos = pos
	_is_open = true
	_prev_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var existing: Array = SignStorage.get_lines(pos)
	for i in range(4):
		_lines[i] = String(existing[i])
	_active_line = 0
	_chevrons_visible = true
	_chevron_blink_accum = 0.0
	visible = true
	set_process(true)
	_refresh_lines()


# Chevron blink driver — toggle every CHEVRON_BLINK_PERIOD seconds.
# Vanilla pv.java: `if (this.i / 6 % 2 == 0) this.h.b = this.j` flips
# the active-line index every 6 ticks; jx.java reads it to decide
# whether to wrap the line in "> ... <" or render it bare.
func _process(delta: float) -> void:
	_chevron_blink_accum += delta
	if _chevron_blink_accum < CHEVRON_BLINK_PERIOD:
		return
	_chevron_blink_accum = 0.0
	_chevrons_visible = not _chevrons_visible
	_refresh_lines()


# Use _unhandled_key_input (not _input) so the SubViewport's internal
# input pipeline doesn't swallow the event before us. _input fires on
# all nodes regardless of focus, but on some Godot 4 builds the
# SubViewportContainer's input forwarding intercepts keystrokes from
# the outer Control tree. _unhandled_key_input fires AFTER the GUI
# input pipeline, on every node, and is the standard hook for "I
# want global key events that nobody else has claimed."
#
# Vanilla pv.java::a(char, int) key mapping (LWJGL keycodes):
#   200 KEY_UP    → this.j = this.j - 1 & 3   (prev line, wrap)
#   208 KEY_DOWN  → this.j = this.j + 1 & 3   (next line, wrap)
#    28 KEY_ENTER → this.j = this.j + 1 & 3   (same as DOWN)
#    14 KEY_BACK  → delete last char on active line
#   printable     → append char if line < 15 chars
# No KEY_TAB — vanilla doesn't bind it. We don't either.
func _unhandled_key_input(event: InputEvent) -> void:
	if not _is_open:
		return
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed:
		return
	var consumed: bool = true
	match key_event.keycode:
		KEY_ESCAPE:
			# Vanilla: bp's default Esc handler closes the GUI. Text is
			# already in the tile entity. We batch-save on close.
			_save_and_close()
		KEY_UP:
			_prev_line()
		KEY_DOWN, KEY_ENTER, KEY_KP_ENTER:
			_advance_line()
		KEY_BACKSPACE:
			_delete_last_char()
		_:
			if _is_printable_unicode(key_event.unicode):
				_insert_char(String.chr(key_event.unicode))
			else:
				consumed = false
	if consumed:
		get_viewport().set_input_as_handled()


# Only ASCII printable chars (0x20..0x7E) — vanilla's FontRenderer only
# has glyphs for printable ASCII, so any other input is silently
# dropped. This keeps our stored strings round-trippable through the
# save format without surprise non-rendering chars.
static func _is_printable_unicode(u: int) -> bool:
	return u >= 0x20 and u <= 0x7E


func _insert_char(ch: String) -> void:
	if _lines[_active_line].length() >= MAX_CHARS_PER_LINE:
		return
	_lines[_active_line] += ch
	_refresh_lines()


func _delete_last_char() -> void:
	var line: String = _lines[_active_line]
	if line.is_empty():
		return
	_lines[_active_line] = line.substr(0, line.length() - 1)
	_refresh_lines()


# Cycle to the next line, wrapping at the bottom. Vanilla pv.java line 51:
# `this.j = this.j + 1 & 3`.
func _advance_line() -> void:
	_active_line = (_active_line + 1) % 4
	_refresh_lines()


# Cycle to the previous line, wrapping at the top. Vanilla pv.java
# line 48: `this.j = this.j - 1 & 3`.
func _prev_line() -> void:
	_active_line = (_active_line + 3) % 4  # +3 instead of -1 to keep modulo positive
	_refresh_lines()


func _refresh_lines() -> void:
	# Text labels never include the chevrons — the chevron pair is a
	# separate Label3D so the text label's rasterized glyph atlas
	# stays stable while the blink toggles.
	for i in range(4):
		if i < _preview_text_labels.size():
			_preview_text_labels[i].text = _lines[i]
	_position_chevrons()


# Position the chevron labels at the active line's left / right edges
# and toggle visibility for the blink. Text width is approximate
# (char count × per-glyph width) since Label3D.get_aabb() may not be
# settled the frame after we mutate text.
func _position_chevrons() -> void:
	if _chevron_left == null or _chevron_right == null:
		return
	var visible_now: bool = _chevrons_visible
	_chevron_left.visible = visible_now
	_chevron_right.visible = visible_now
	if not visible_now:
		return
	# Live text width via Font.get_string_size — Label3D.get_aabb()
	# lags by one frame (still reports the previous text's size right
	# after we mutate .text), which caused the chevrons to creep into
	# the new character on every keystroke. Asking the font directly
	# gives the correct width synchronously, in font pixels; multiply
	# by pixel_size to convert to world meters.
	var active_label: Label3D = _preview_text_labels[_active_line]
	var line_text: String = _lines[_active_line]
	var glyph_px: float = 0.0
	if active_label.font != null:
		glyph_px = (
			active_label
			. font
			. get_string_size(line_text, HORIZONTAL_ALIGNMENT_LEFT, -1, active_label.font_size)
			. x
		)
	# Floor at ~2 chars wide so an empty / single-char line still keeps
	# the chevrons apart at the center instead of overlapping.
	var min_world_width: float = 24.0 * SignNode.TEXT_PIXEL_SIZE
	# 1.15× buffer on the measured width — Font.get_string_size returns
	# the sum of advance widths, while Label3D's rendered glyphs include
	# a small extra inset that the bare advance under-counts. Without
	# the buffer the chevrons crept into the text once it grew past
	# ~4 characters.
	var text_width: float = maxf(glyph_px * active_label.pixel_size * 1.15, min_world_width)
	# Gap between text edge and chevron — wide enough that a full-width
	# glyph (≈ 12 px at font_size 24) at the text edge can't touch the
	# chevron glyph drawn to its outside.
	var gap: float = 14.0 * SignNode.TEXT_PIXEL_SIZE
	# Match the same shift the text labels use (see _build_preview_panel)
	# so chevrons sit vertically centred on the text.
	var line_y: float = (1.5 - float(_active_line)) * SignNode.LINE_HEIGHT + 0.015625
	var face_z: float = 0.0625 + 0.01
	_chevron_left.position = Vector3(-text_width / 2.0 - gap, line_y, face_z)
	_chevron_right.position = Vector3(text_width / 2.0 + gap, line_y, face_z)


# Commit all 4 lines to SignStorage, which fires text_changed and
# refreshes the in-world SignNode labels live, then dismiss.
func _save_and_close() -> void:
	for i in range(4):
		SignStorage.set_text(_target_pos, i, _lines[i])
	_close_internal()


func _close_internal() -> void:
	_is_open = false
	visible = false
	set_process(false)
	Input.mouse_mode = _prev_mouse_mode


# Used by player.gd's _physics_process to freeze the body while the
# editor is open, so WASD / Space don't leak into movement.
func is_open() -> bool:
	return _is_open
