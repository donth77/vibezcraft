class_name MinecraftFont
extends RefCounted

# Builds a bitmap FontFile from `assets/fonts/ascii.png` (16x16 grid of 8x8
# glyphs, ASCII 0-255). Vanilla Alpha's FontRenderer reads the same sheet and
# computes per-glyph widths by scanning each 8x8 cell from the right edge for
# the first column with any non-transparent pixel — we replicate that here so
# proportional spacing matches MC.
#
# Why a runtime-built FontFile instead of the OTF: MC's font is pixel-grid
# native (8 px tall). Godot's TTF/OTF rasterizer at sizes that aren't exact
# multiples of 8 (e.g. 10, 12, 18, 22, 30, 36) still produces uneven glyph
# heights — even with antialiasing=0 — because the rasterizer rounds per-glyph
# metrics, not the whole sheet. A bitmap FontFile sidesteps that: the source
# is one 8 px sheet, and Godot scales it via the texture filter (nearest, set
# project-wide), so any requested size renders as integer-aligned blocks.

const SHEET_PATH := "res://assets/fonts/ascii.png"
const CELL := 8  # glyph cell size in source pixels
const COLS := 16
const ROWS := 16

# Returns a FontFile ready to be assigned as ThemeDB.fallback_font or as a
# theme's default_font. Cached after first build.
static var _cached: FontFile = null


static func get_font() -> FontFile:
	if _cached != null:
		return _cached
	_cached = _build()
	return _cached


static func _build() -> FontFile:
	var tex: Texture2D = load(SHEET_PATH)
	if tex == null:
		push_error("[MinecraftFont] failed to load %s" % SHEET_PATH)
		return null
	var img: Image = tex.get_image()
	if img == null:
		push_error("[MinecraftFont] texture has no image data")
		return null
	# Force RGBA8 so get_pixel().a is reliable; the imported sheet is RGBA
	# already, but compressed import variants may decode to a different format.
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)

	var font := FontFile.new()
	font.fixed_size = CELL
	# Default fixed_size_scale_mode is DISABLE, which makes Godot ignore the
	# requested font_size and always render at the source CELL — that's why
	# every screen rendered as 8 px tiny text. ENABLED lets it scale up to the
	# requested size; with default_texture_filter=0 (nearest) project-wide,
	# scaling stays crisp. INTEGER_ONLY would be even crisper but would round
	# font_size down to the nearest 8-multiple and silently shift layouts.
	font.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_ENABLED
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.hinting = TextServer.HINTING_NONE
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	font.force_autohinter = false
	font.allow_system_fallback = false
	font.multichannel_signed_distance_field = false
	font.generate_mipmaps = false

	# Cache index 0, size (CELL, 0) = font_size CELL, no outline.
	# Vanilla MC has 7 px above baseline + 1 px descender (g/p/q/y dip 1 row).
	var ascent := 7.0
	var descent := 1.0
	var size_key := Vector2i(CELL, 0)
	font.set_cache_ascent(0, CELL, ascent)
	font.set_cache_descent(0, CELL, descent)
	# One texture page holding the full 128x128 sheet.
	font.set_texture_image(0, size_key, 0, img)

	for code in range(0, COLS * ROWS):
		var col: int = code % COLS
		var row: int = code / COLS
		var x0: int = col * CELL
		var y0: int = row * CELL
		var advance: int = _measure_advance(img, x0, y0)
		# Space (0x20) has no visible pixels — use vanilla's 4 px advance.
		if code == 0x20:
			advance = 4
		# Visible glyph width = advance minus the 1 px inter-glyph spacing the
		# advance includes. UV rect and rendered size both cover only the
		# visible columns — without this, narrow glyphs (i, l, .) render as
		# full 8 px squares and text comes out far wider than the OTF version,
		# blowing past button widths and shifting visual center.
		var visible_w: int = max(advance - 1, 1)
		font.set_glyph_advance(0, CELL, code, Vector2(advance, 0))
		# Y offset positions glyph TOP relative to baseline. With offset.y=0
		# Godot draws the cell below the baseline → text sits at the bottom of
		# the line box. Setting it to -ascent puts the glyph cell straddling
		# the baseline correctly: ascent rows above, descent rows below.
		font.set_glyph_offset(0, size_key, code, Vector2(0.0, -ascent))
		font.set_glyph_size(0, size_key, code, Vector2(visible_w, CELL))
		font.set_glyph_uv_rect(0, size_key, code, Rect2(x0, y0, visible_w, CELL))
		font.set_glyph_texture_idx(0, size_key, code, 0)

	return font


# Vanilla algorithm: rightmost column with any non-transparent pixel, +1 for
# the column itself, +1 for inter-glyph spacing.
static func _measure_advance(img: Image, x0: int, y0: int) -> int:
	for col in range(CELL - 1, -1, -1):
		for row in range(CELL):
			if img.get_pixel(x0 + col, y0 + row).a > 0.0:
				return col + 2
	return 0
