class_name ChatHud
extends Control

# Vanilla GuiNewChat.drawChat port (Spoutcraft mirror of MC 1.6.x —
# Alpha 1.2.6 itself had only a 5-line scrollback; we adopt the Beta+
# 10-line fade-out chat HUD since it's the version players recognize).
# Bottom-left message log just above the HUD bars. Newest message at
# the bottom; older lines stack upward; entries fade out after 10 s.
# Read-only — no input field, no command parsing (we're single-player).
#
# Public API. Any script can `ChatHud.push("message")` without owning
# a reference; the most recent ChatHud node registers itself as the
# active instance via the `_instance` static.
#
# Vanilla constants from drawChat (GuiNewChat.java lines 73-92):
#   * LIFETIME = 200 ticks (10 s @ 20 TPS).
#   * Fade curve: `inv = 1 - elapsed/200; inv = clamp(inv*10, 0, 1);
#     alpha = inv*inv`. Stays at full opacity until the LAST 20 ticks
#     (1 s), then squared ease-out to 0.
#   * Background rect: `bg_alpha = text_alpha / 2` (half opacity).
#   * Line height: 9 px (= FONT_HEIGHT 8 + 1 px padding).
#   * Text: 0xFFFFFF (white) with 1 px black drop shadow via
#     drawStringWithShadow.
#   * Max visible: 10 lines (func_96127_i default).
#
# Font: the project's `MinecraftFont` bitmap (8 px source cell scaled
# via nearest filter) so the HUD reads the same as every other UI
# screen. Scale factor 2 gives 16-px-tall lines — readable at modern
# resolutions without losing the pixel-font look.

const _LIFETIME_SEC: float = 10.0
const _MAX_MESSAGES: int = 10
# Font cell = 8 px (vanilla). Scale 4 matches the project's existing UI
# (pause_menu / inventory_screen run at 4-5×) so chat text reads the
# same size as menu titles + button labels. Line height stays the
# vanilla 9 px × scale relationship.
const _FONT_SCALE: int = 4
const _FONT_CELL: int = 8
const _FONT_SIZE: int = _FONT_CELL * _FONT_SCALE  # 32
const _LINE_HEIGHT: int = 9 * _FONT_SCALE  # 36 — vanilla 9 px × scale
const _TEXT_X: int = 2 * _FONT_SCALE
const _BG_RIGHT_PAD: int = 4 * _FONT_SCALE  # vanilla: bg_w = text_w + 4
const _SHADOW_OFFSET: int = _FONT_SCALE  # 1 px in vanilla, scaled

static var _instance: ChatHud = null
var _messages: Array = []  # [{text: String, age: float}, ...]
var _font: Font = null


# Push a message to the chat log. Wrap-to-width is NOT performed —
# vanilla wraps via FontRenderer.listFormattedStringToWidth, but for
# the system messages we currently emit (bed reject, death notes) the
# strings are short enough that wrap isn't needed. Long messages will
# overflow the screen right edge rather than soft-wrap.
static func push(text: String) -> void:
	if _instance == null:
		push_warning("[ChatHud] push() before instance ready: %s" % text)
		return
	_instance._messages.append({"text": text, "age": 0.0})
	while _instance._messages.size() > _MAX_MESSAGES:
		_instance._messages.pop_front()
	_instance.queue_redraw()


func _ready() -> void:
	_instance = self
	_font = MinecraftFont.get_font()
	set_process(true)
	mouse_filter = MOUSE_FILTER_IGNORE


func _exit_tree() -> void:
	if _instance == self:
		_instance = null


func _process(delta: float) -> void:
	if _messages.is_empty():
		return
	for msg in _messages:
		msg.age += delta
	# Drop expired (FIFO order). Vanilla doesn't remove expired entries
	# from the model — it just gates display on `var11 < 200`. Removing
	# them here is functionally equivalent and keeps the array bounded
	# even if `push` is called in a tight loop with `>MAX_MESSAGES`.
	while not _messages.is_empty() and _messages[0].age >= _LIFETIME_SEC:
		_messages.pop_front()
	queue_redraw()


func _draw() -> void:
	if _messages.is_empty() or _font == null:
		return
	# Stack from newest (bottom) to oldest (top). Vanilla iterates with
	# `var9 = 0..max` building -var9*9 Y offsets above the chat origin;
	# we mirror that by walking the array in reverse and using negative
	# Y to anchor at the Control's bottom edge.
	var stack_idx: int = 0
	for i in range(_messages.size() - 1, -1, -1):
		var msg: Dictionary = _messages[i]
		var alpha: float = _alpha_for_age(msg.age)
		if alpha <= 0.0:
			continue
		var y_top: float = -float(_LINE_HEIGHT) - float(stack_idx * _LINE_HEIGHT)
		var text: String = msg.text
		var text_size: Vector2 = _font.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, _FONT_SIZE
		)
		# Vanilla rect width = text width + 4 px (post-text padding) and
		# starts at the left edge (no left pad — text begins at +2 inside
		# the rect, so the rect extends to text_x + text_w + 4).
		var bg_w: float = float(_TEXT_X) + text_size.x + float(_BG_RIGHT_PAD)
		var bg_color := Color(0.0, 0.0, 0.0, alpha * 0.5)
		var text_color := Color(1.0, 1.0, 1.0, alpha)
		var shadow_color := Color(0.0, 0.0, 0.0, alpha)
		draw_rect(Rect2(0.0, y_top, bg_w, float(_LINE_HEIGHT)), bg_color)
		# Godot's draw_string positions at the BASELINE. The vanilla
		# font's baseline sits 7 px from the cell top (1 px descent).
		# Scale that for our chosen font scale.
		var baseline_y: float = y_top + float(7 * _FONT_SCALE)
		draw_string(
			_font,
			Vector2(float(_TEXT_X + _SHADOW_OFFSET), baseline_y + float(_SHADOW_OFFSET)),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			_FONT_SIZE,
			shadow_color
		)
		draw_string(
			_font,
			Vector2(float(_TEXT_X), baseline_y),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			_FONT_SIZE,
			text_color
		)
		stack_idx += 1


# Vanilla fade curve. Identical math to GuiNewChat.drawChat lines
# 73-82, just sourced from wall seconds instead of ticks:
#   inv = 1 - elapsed_ticks / 200
#   inv = clamp(inv * 10, 0, 1)
#   alpha = inv * inv
# Returns 1.0 while elapsed < 18 ticks remain, then squared ease-out
# to 0 over the last ~20 ticks (1 s).
static func _alpha_for_age(age: float) -> float:
	if age >= _LIFETIME_SEC:
		return 0.0
	var ticks: float = age * 20.0  # convert wall seconds → vanilla ticks
	var inv: float = 1.0 - ticks / 200.0
	var scaled: float = clampf(inv * 10.0, 0.0, 1.0)
	return scaled * scaled
