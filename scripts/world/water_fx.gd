extends Node

# Per-frame driver for the procedural 16×16 water texture. Owns a
# `WaterFXNative` (ports vanilla Alpha 1.2.6 oe.java's TextureWaterFX
# cellular automaton) and an `ImageTexture` that the water shader samples.
#
# Vanilla ran this filter every game tick (20 Hz) and rewrote one of the
# 16 animation frames in terrain.png. We tick it every render frame and
# bind it as a uniform `water_fx_tex` on `BlockAtlas.water_material()`.
# Each tick is ~25µs (256 cells × ~100ns of float math), so the cost is
# below the noise floor of even a 240Hz frame.
#
# Behavior on cold start: the buffers are all zero, so the first few
# frames produce a flat dim texture. The 5%-per-cell impulse spawn rate
# means after ~20 ticks the field is fully populated. To avoid the
# visible ramp-in at game launch, we pre-tick 60 frames in `_ready`.

const _GRID: int = 16
const _BYTES_PER_CELL: int = 4

var _fx: Object  # WaterFXNative — typed as Object so the script loads
# even without the GDExtension built.
var _texture: ImageTexture
var _image: Image


func _ready() -> void:
	if not ClassDB.class_exists("WaterFXNative"):
		# Native extension isn't built. Disable per-frame ticking and
		# fall back to the shader's procedural ripple — same look the
		# project shipped with before this filter landed.
		set_process(false)
		return
	_fx = ClassDB.instantiate("WaterFXNative")
	# Seed with a fixed value so cold-start visuals are deterministic
	# across launches (matches every other RNG in this codebase).
	_fx.set_seed(0x5761746572_4658)
	_image = Image.create_empty(_GRID, _GRID, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	# Pre-roll so the first visible frame already has a populated field —
	# without this the surface starts black and ramps in over ~1s.
	for i in range(60):
		_fx.tick()
	_apply_to_water_material()


func _process(_delta: float) -> void:
	if _fx == null:
		return
	var bytes: PackedByteArray = _fx.tick()
	# Image.set_data wants a tightly-packed RGBA8 buffer of width*height*4
	# bytes — exactly what WaterFXNative.tick() returns.
	_image.set_data(_GRID, _GRID, false, Image.FORMAT_RGBA8, bytes)
	_texture.update(_image)


# Push the live texture onto the shared water ShaderMaterial. The
# material is created lazily in BlockAtlas.water_material() so chunks
# loaded before this autoload runs still pick up the uniform once we
# write it (ShaderMaterial uniforms are setter-driven, not snapshot).
func _apply_to_water_material() -> void:
	var mat: ShaderMaterial = BlockAtlas.water_material()
	mat.set_shader_parameter("water_fx_tex", _texture)
