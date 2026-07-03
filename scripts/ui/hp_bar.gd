extends Control

# Vanilla MC HUD heart row — 10 hearts laid out horizontally above the
# hotbar. Each heart represents 2 HP (full / half / empty). Sources its
# sprites from gui/icons.png at the canonical 9×9 atlas coords:
#   (16, 0) heart container (gray background)
#   (25, 0) container, damage-flash variant (white)
#   (52, 0) full red heart
#   (61, 0) half red heart
#   (70, 0) full white heart (damage flash of pre-hit health)
#   (79, 0) half white heart
# Drawn at SCALE = 4 to match the hotbar's chunky pixel-art density.

const ICONS_PATH: String = "res://assets/textures/gui/icons.png"
const HEART_PX: int = 9
const HEART_STRIDE: int = 8  # vanilla packs hearts 8 px apart, 1 px overlap
const SCALE: int = 4
const HEARTS: int = 10  # 10 hearts × 2 HP = 20

const _ATLAS_BG: Rect2 = Rect2(16, 0, HEART_PX, HEART_PX)
const _ATLAS_BG_FLASH: Rect2 = Rect2(25, 0, HEART_PX, HEART_PX)
const _ATLAS_FULL: Rect2 = Rect2(52, 0, HEART_PX, HEART_PX)
const _ATLAS_HALF: Rect2 = Rect2(61, 0, HEART_PX, HEART_PX)
const _ATLAS_FULL_FLASH: Rect2 = Rect2(70, 0, HEART_PX, HEART_PX)
const _ATLAS_HALF_FLASH: Rect2 = Rect2(79, 0, HEART_PX, HEART_PX)

# Vanilla low-health tremble — nl.java:96-98: while health <= 4 every
# heart drops 0..1 native px, re-rolled once per HUD tick (the RNG is
# reseeded per tick at nl.java:73, i.e. 20 Hz — not per frame).
const _LOW_HEALTH_JITTER_HP: int = 4
const _HUD_TICK_SEC: float = 0.05

# Vanilla damage flash — nl.java:67-70: while the hurt timer is >= 10
# (the first half of the 20-tick window) the row blinks on a 3-tick
# cadence: every container swaps to its white variant and the PRE-HIT
# health draws in white hearts underneath the red row (nl.java:99-107),
# so exactly the hearts just lost read as blinking. Hearts never move
# on damage in vanilla — the flash is the whole damage reaction.
const _FLASH_TICKS_TOTAL: int = 20
const _FLASH_BLINK_MIN_TICKS: int = 10

var _bg_rects: Array = []  # Array[TextureRect]
var _flash_rects: Array = []  # Array[TextureRect] — white prev-health layer
var _fill_rects: Array = []  # Array[TextureRect]
var _current_hp: int = 20
var _jitter_accum: float = 0.0
var _jitter_active: bool = false
var _flash_prev_hp: int = 0
var _flash_ticks: int = 0
var _flash_accum: float = 0.0
var _flash_on: bool = false
var _player: Node


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_hearts()
	_player = get_tree().root.get_node_or_null("Main/Player")
	if _player != null:
		if _player.has_signal("health_changed"):
			_player.health_changed.connect(_on_health_changed)
	# Initial draw
	if _player != null and "health" in _player:
		_refresh(_player.health)
	else:
		_refresh(20)


func _process(delta: float) -> void:
	_tick_flash(delta)
	_tick_jitter(delta)


# Damage flash — counts the 20-tick hurt window down at HUD cadence and
# toggles the white layer on the vanilla 3-tick blink (see const block).
func _tick_flash(delta: float) -> void:
	if _flash_ticks <= 0:
		return
	_flash_accum += delta
	while _flash_accum >= _HUD_TICK_SEC and _flash_ticks > 0:
		_flash_accum -= _HUD_TICK_SEC
		_flash_ticks -= 1
	var blink: bool = _flash_ticks >= _FLASH_BLINK_MIN_TICKS and (_flash_ticks / 3) % 2 == 1
	if blink != _flash_on:
		_flash_on = blink
		_apply_flash_visuals()


func _tick_jitter(delta: float) -> void:
	if _current_hp > _LOW_HEALTH_JITTER_HP:
		if _jitter_active:
			# Climbed back above the threshold — park the row at rest.
			_jitter_active = false
			for i in range(_bg_rects.size()):
				(_bg_rects[i] as TextureRect).position.y = 0.0
				(_flash_rects[i] as TextureRect).position.y = 0.0
				(_fill_rects[i] as TextureRect).position.y = 0.0
		return
	_jitter_active = true
	_jitter_accum += delta
	if _jitter_accum < _HUD_TICK_SEC:
		return
	_jitter_accum = fmod(_jitter_accum, _HUD_TICK_SEC)
	# Each heart independently drops 0 or 1 native px (scaled) this tick —
	# vanilla's dying tremble. Vertical only: jittering x instead walked
	# hearts sideways into their neighbors (issue #4 "hearts collide").
	# All three layers (container / white flash / red fill) share the
	# offset, matching vanilla's per-heart row offset.
	for i in range(_bg_rects.size()):
		var y_offset: int = (randi() % 2) * SCALE
		(_bg_rects[i] as TextureRect).position.y = y_offset
		(_flash_rects[i] as TextureRect).position.y = y_offset
		(_fill_rects[i] as TextureRect).position.y = y_offset


# Swap every container to/from the flash variant and show the pre-hit
# health in the white layer. The red fill draws on top, so only the
# hearts actually lost read as blinking white — vanilla nl.java:99-112
# draw order (container → white prev-health → red current-health).
func _apply_flash_visuals() -> void:
	for i in range(HEARTS):
		var bg: TextureRect = _bg_rects[i]
		(bg.texture as AtlasTexture).region = _ATLAS_BG_FLASH if _flash_on else _ATLAS_BG
		var flash: TextureRect = _flash_rects[i]
		if not _flash_on:
			flash.visible = false
			continue
		var prev_for_this: int = clampi(_flash_prev_hp - i * 2, 0, 2)
		if prev_for_this == 2:
			(flash.texture as AtlasTexture).region = _ATLAS_FULL_FLASH
			flash.visible = true
		elif prev_for_this == 1:
			(flash.texture as AtlasTexture).region = _ATLAS_HALF_FLASH
			flash.visible = true
		else:
			flash.visible = false


func _build_hearts() -> void:
	var sheet: Texture2D = load(ICONS_PATH) as Texture2D
	for i in range(HEARTS):
		var x: int = i * HEART_STRIDE * SCALE
		var bg: TextureRect = _make_heart(sheet, _ATLAS_BG)
		bg.position = Vector2(x, 0)
		add_child(bg)
		_bg_rects.append(bg)
		# White damage-flash layer sits between container and red fill —
		# vanilla draw order (nl.java:99 → 100-107 → 108-112).
		var flash: TextureRect = _make_heart(sheet, _ATLAS_FULL_FLASH)
		flash.position = Vector2(x, 0)
		flash.visible = false
		add_child(flash)
		_flash_rects.append(flash)
		var fill: TextureRect = _make_heart(sheet, _ATLAS_FULL)
		fill.position = Vector2(x, 0)
		fill.visible = false
		add_child(fill)
		_fill_rects.append(fill)
	# Sized to the row footprint so anchor-positioning works in the scene.
	custom_minimum_size = Vector2(HEARTS * HEART_STRIDE * SCALE, HEART_PX * SCALE)


func _make_heart(sheet: Texture2D, region: Rect2) -> TextureRect:
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = region
	var tr := TextureRect.new()
	tr.texture = atlas
	tr.size = Vector2(HEART_PX * SCALE, HEART_PX * SCALE)
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


func _on_health_changed(current: int, _maximum: int) -> void:
	# Health dropped — latch the pre-hit value and start the vanilla
	# 20-tick flash window (nl.java: K holds the pre-damage health the
	# white layer renders). Heals never flash.
	if current < _current_hp:
		_flash_prev_hp = _current_hp
		_flash_ticks = _FLASH_TICKS_TOTAL
		_flash_accum = 0.0
	_refresh(current)


# Each heart slot covers 2 HP. Hearts 0..(N/2) are full; if HP is odd,
# the next heart is half; the rest are empty (just bg).
func _refresh(current_hp: int) -> void:
	_current_hp = current_hp
	for i in range(HEARTS):
		var hp_for_this: int = clampi(current_hp - i * 2, 0, 2)
		var fill: TextureRect = _fill_rects[i]
		if hp_for_this == 2:
			(fill.texture as AtlasTexture).region = _ATLAS_FULL
			fill.visible = true
		elif hp_for_this == 1:
			(fill.texture as AtlasTexture).region = _ATLAS_HALF
			fill.visible = true
		else:
			fill.visible = false
