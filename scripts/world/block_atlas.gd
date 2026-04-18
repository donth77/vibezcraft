class_name BlockAtlas
extends RefCounted

# Packs the per-block textures from assets/textures/blocks/packs/{active}/
# into a single atlas. Cell size is auto-detected from the first texture, so
# 16×16 / 32×32 / any-square packs all work without code changes. Active
# pack is configured in the Game autoload.

const GRID_SIZE := 4  # 4x4 = 16 slots; we use 11
const PACK_BASE := "res://assets/textures/blocks/packs/"
const DEFAULT_PACK := "pixellab"

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

static var active_pack: String = DEFAULT_PACK
static var _texture: ImageTexture
static var _uv_rects: Dictionary = {}
static var _material: ShaderMaterial
static var _slot_size: int = 32  # auto-detected on build()


static func build() -> void:
	# Auto-detect slot size from the first available texture in this pack
	var first_tex: Texture2D = _load_first_texture()
	if first_tex != null:
		_slot_size = first_tex.get_width()
	print("[BlockAtlas] pack=%s slot_size=%d" % [active_pack, _slot_size])

	var atlas_image := Image.create(
		_slot_size * GRID_SIZE, _slot_size * GRID_SIZE, false, Image.FORMAT_RGBA8
	)
	var slot_uv: float = 1.0 / float(GRID_SIZE)
	for tex_name: String in _LAYOUT:
		var idx: int = _LAYOUT[tex_name]
		var col: int = idx % GRID_SIZE
		var row: int = idx / GRID_SIZE
		var path := "%s%s/%s.png" % [PACK_BASE, active_pack, tex_name]
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
		if img.get_width() != _slot_size or img.get_height() != _slot_size:
			# Resize mismatched textures to slot size with nearest-neighbor
			img.resize(_slot_size, _slot_size, Image.INTERPOLATE_NEAREST)
		atlas_image.blit_rect(
			img, Rect2i(0, 0, _slot_size, _slot_size), Vector2i(col * _slot_size, row * _slot_size)
		)
		_uv_rects[tex_name] = Rect2(col * slot_uv, row * slot_uv, slot_uv, slot_uv)
	_texture = ImageTexture.create_from_image(atlas_image)


# Tries each layout texture in turn and returns the first one that loads,
# so we can detect slot size before the main atlas-build loop.
static func _load_first_texture() -> Texture2D:
	for tex_name: String in _LAYOUT:
		var path := "%s%s/%s.png" % [PACK_BASE, active_pack, tex_name]
		var tex := load(path) as Texture2D
		if tex != null:
			return tex
	return null


static func texture() -> ImageTexture:
	if _texture == null:
		build()
	return _texture


static func uv_rect(tex_name: String) -> Rect2:
	if _uv_rects.is_empty():
		build()
	return _uv_rects.get(tex_name, Rect2(0, 0, 0, 0))


# Single ShaderMaterial shared across every chunk. Called from the main thread
# only (chunk_node._ready); materials are RefCounted so sharing is safe.
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = load("res://shaders/chunk.gdshader") as Shader
		_material.set_shader_parameter("atlas_texture", texture())
	return _material


static func reset() -> void:
	_texture = null
	_uv_rects = {}
	_material = null
