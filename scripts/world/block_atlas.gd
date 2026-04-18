class_name BlockAtlas
extends RefCounted

# Packs the per-block textures from assets/textures/blocks/raw/ into a single atlas.
# Built once at startup; texture stays resident as a static var.

const SLOT_SIZE := 32
const GRID_SIZE := 4  # 4x4 = 16 slots; we use 11

const _LAYOUT := {
	"stone": 0,
	"cobblestone": 1,
	"dirt": 2,
	"grass_top": 3,
	"grass_side": 4,
	"bedrock": 5,
	"sand": 6,
	"log_top": 7,
	"log_side": 8,
	"planks": 9,
	"leaves": 10,
}

static var _texture: ImageTexture
static var _uv_rects: Dictionary = {}


static func build() -> void:
	var atlas_image := Image.create(
		SLOT_SIZE * GRID_SIZE, SLOT_SIZE * GRID_SIZE, false, Image.FORMAT_RGBA8
	)
	var slot_uv: float = 1.0 / float(GRID_SIZE)
	for tex_name: String in _LAYOUT:
		var idx: int = _LAYOUT[tex_name]
		var col: int = idx % GRID_SIZE
		var row: int = idx / GRID_SIZE
		var path := "res://assets/textures/blocks/raw/%s.png" % tex_name
		var tex := load(path) as Texture2D
		if tex == null:
			push_error("BlockAtlas: failed to load %s" % path)
			continue
		var img := tex.get_image()
		if img == null:
			push_error("BlockAtlas: %s has no image data" % path)
			continue
		if img.is_compressed():
			img.decompress()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		if img.get_width() != SLOT_SIZE or img.get_height() != SLOT_SIZE:
			push_warning(
				(
					"BlockAtlas: %s is %dx%d, expected %dx%d"
					% [tex_name, img.get_width(), img.get_height(), SLOT_SIZE, SLOT_SIZE]
				)
			)
		atlas_image.blit_rect(
			img, Rect2i(0, 0, SLOT_SIZE, SLOT_SIZE), Vector2i(col * SLOT_SIZE, row * SLOT_SIZE)
		)
		_uv_rects[tex_name] = Rect2(col * slot_uv, row * slot_uv, slot_uv, slot_uv)
	_texture = ImageTexture.create_from_image(atlas_image)


static func texture() -> ImageTexture:
	if _texture == null:
		build()
	return _texture


static func uv_rect(tex_name: String) -> Rect2:
	if _uv_rects.is_empty():
		build()
	return _uv_rects.get(tex_name, Rect2(0, 0, 0, 0))


static func reset() -> void:
	_texture = null
	_uv_rects = {}
