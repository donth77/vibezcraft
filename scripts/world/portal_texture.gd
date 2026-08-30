class_name PortalTexture
extends RefCounted

# Alpha 1.2.6's animated portal texture — a port of `et.java`.
# See docs/nether-alpha-1.2.6-implementation-plan.md §7.1.
#
# terrain.png's portal tile is a flat blue placeholder; vanilla overwrites
# it at runtime with 32 procedurally generated frames. The generator is
# fully deterministic — `new Random(100L)`, walked in a fixed order — so
# the frames are identical in every session and every install, which is
# why the plan can ask for frame hashes.
#
# Two per-pixel swirls are summed, each rotated by the frame index and
# warped by distance from its own centre, then a small amount of noise is
# added from the seeded Random. The result is the familiar purple churn.
#
# One shared texture set, built once. The plan forbids a material or
# texture per portal block.

const FRAMES: int = 32
const SIZE: int = 16

# et.java:13 — the seed is a literal 100.
const SEED: int = 100

# Vanilla advances one frame per client tick, so the loop is 32 ticks at
# 20 Hz — a hair over 1.6 seconds.
const FRAME_SECONDS: float = 1.0 / 20.0

static var _frames: Array[Image] = []
static var _textures: Array[ImageTexture] = []
static var _strip: ImageTexture = null


static func reset() -> void:
	_frames.clear()
	_textures.clear()
	_strip = null


# Build all 32 frames. Idempotent; the first call does the work.
static func ensure_built() -> void:
	if _frames.size() == FRAMES:
		return
	_frames.clear()
	_textures.clear()
	var rng := JavaRandom.new(SEED)
	for frame: int in range(FRAMES):
		var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
		for px: int in range(SIZE):
			for py: int in range(SIZE):
				# et.java:15-17 — the loops are `i3` over one axis and
				# `i4` over the other, and the write index is
				# `i4 * 16 + i3`, so i3 is X and i4 is Y.
				var total: float = 0.0
				for layer: int in range(2):
					# Both layers use the same offset for their two axes;
					# layer 0 is centred at 0 and layer 1 at 8.
					var offset: float = float(layer * 8)
					var fx: float = (float(px) - offset) / 16.0 * 2.0
					var fy: float = (float(py) - offset) / 16.0 * 2.0
					if fx < -1.0:
						fx += 2.0
					if fx >= 1.0:
						fx -= 2.0
					if fy < -1.0:
						fy += 2.0
					if fy >= 1.0:
						fy -= 2.0
					var radius_sq: float = fx * fx + fy * fy
					# The rotation term flips sign between the two layers
					# (`layer * 2 - 1`), which is what makes them counter-
					# rotate instead of smearing together.
					var angle: float = (
						atan2(fy, fx)
						+ (
							(float(frame) / 32.0 * PI * 2.0 - radius_sq * 10.0 + float(layer * 2))
							* float(layer * 2 - 1)
						)
					)
					# Alpha's table sine, not sin() — see AlphaMath.
					var wave: float = (AlphaMath.sin_table(angle) + 1.0) / 2.0
					wave /= radius_sq + 1.0
					total += wave * 0.5
				# et.java:41 — the seeded noise. Drawn once per pixel in
				# a fixed order, which is what makes the whole set
				# reproducible.
				total += rng.next_float() * 0.1
				var r: int = int(total * total * 200.0 + 55.0)
				var g: int = int(total * total * total * total * 255.0)
				var b: int = int(total * 100.0 + 155.0)
				var a: int = int(total * 100.0 + 155.0)
				img.set_pixel(
					px,
					py,
					Color8(
						clampi(r, 0, 255), clampi(g, 0, 255), clampi(b, 0, 255), clampi(a, 0, 255)
					)
				)
		_frames.append(img)
		_textures.append(ImageTexture.create_from_image(img))


static func frame_image(index: int) -> Image:
	ensure_built()
	return _frames[posmod(index, FRAMES)]


static func frame_texture(index: int) -> ImageTexture:
	ensure_built()
	return _textures[posmod(index, FRAMES)]


# All 32 frames stacked into one 16x512 image, frame 0 at the top.
#
# This is what the portal shader samples. Animating by moving V down a
# strip means the whole effect is one shared texture and one shared
# material for every portal in the world — no per-frame upload, and no
# per-block resource, which is what the plan requires.
static func strip_texture() -> ImageTexture:
	if _strip != null:
		return _strip
	ensure_built()
	var strip := Image.create(SIZE, SIZE * FRAMES, false, Image.FORMAT_RGBA8)
	var region := Rect2i(0, 0, SIZE, SIZE)
	for frame: int in range(FRAMES):
		strip.blit_rect(_frames[frame], region, Vector2i(0, frame * SIZE))
	_strip = ImageTexture.create_from_image(strip)
	return _strip


# Which frame is showing at a given elapsed time. Vanilla ticks one frame
# per client tick and wraps.
static func frame_at(elapsed_seconds: float) -> int:
	return posmod(int(elapsed_seconds / FRAME_SECONDS), FRAMES)


# sha256 of one frame's raw pixels. The plan asks for deterministic frame
# hashes, and this is what the test compares against a checked-in list.
static func frame_hash(index: int) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(frame_image(index).get_data())
	return ctx.finish().hex_encode()
