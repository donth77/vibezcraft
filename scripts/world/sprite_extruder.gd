class_name SpriteExtruder
extends RefCounted

# Voxelizes a 2D pixel-art sprite into a 3D extruded mesh — each opaque
# pixel becomes a thin voxel with depth, matching vanilla MC's
# ItemModelGenerator. Used for held tools (pickaxes, swords, etc) so they
# look like chunky 3D objects in the player's hand instead of flat paper.
#
# Mesh dimensions are in PIXEL UNITS centered at origin:
#   width  = texture_width  px
#   height = texture_height px
#   depth  = THICKNESS       px
# Caller scales the MeshInstance3D to map pixels to world units.
#
# Each opaque pixel emits its own UV-mapped front + back face, plus side
# faces only where the adjacent pixel is transparent (chunk-mesher style
# neighbor culling). Cached per texture path.

# Vanilla MC ItemModelGenerator uses 1.0 (1px on a 16px sprite). Vanilla
# can get away with 1px because of GUI scaling and tighter shading
# contrast; at our perspective-camera render distance, 1-2px visible
# depth is sub-pixel and the tool reads as flat paper. 4.0 (~25%) gives
# real visible bulk on each side without looking like a brick.
const THICKNESS: float = 2.0

static var _cache: Dictionary = {}


# Finds the bottom-most opaque pixel in the texture and returns its
# position in MESH-LOCAL coordinates (post Y-flip, pre-scale). For tool
# sprites, this is the tip of the handle — the natural rotation pivot
# when the tool is gripped in a fist. Caller multiplies by their scale
# to get the offset to apply when positioning the mesh inside its pivot
# parent.
static func get_handle_pivot_offset(texture: Texture2D) -> Vector2:
	if texture == null:
		return Vector2.ZERO
	var img: Image = texture.get_image()
	if img == null:
		return Vector2.ZERO
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w: int = img.get_width()
	var h: int = img.get_height()
	var hx: float = float(w) * 0.5
	var hy: float = float(h) * 0.5
	# Scan from bottom (highest image y) upward — first opaque pixel found
	# is the bottom-most. For pickaxes that's the handle tip (lower-left).
	for y in range(h - 1, -1, -1):
		for x in range(w):
			if img.get_pixel(x, y).a > 0.5:
				# Y-flip: image y → mesh +Y (top of texture is up).
				return Vector2(float(x) - hx, float(h - 1 - y) - hy)
	return Vector2.ZERO


static func build(texture: Texture2D) -> ArrayMesh:
	if texture == null:
		return null
	var key: String = texture.resource_path
	if key != "" and _cache.has(key):
		return _cache[key]
	var mesh: ArrayMesh = _build_uncached(texture)
	if key != "":
		_cache[key] = mesh
	return mesh


static func _build_uncached(texture: Texture2D) -> ArrayMesh:
	var img: Image = texture.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w: int = img.get_width()
	var h: int = img.get_height()

	# Build alpha mask once so the inner loops don't re-sample the image.
	var opaque: Array = []
	for y in range(h):
		var row: Array = []
		for x in range(w):
			row.append(img.get_pixel(x, y).a > 0.5)
		opaque.append(row)

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var indices := PackedInt32Array()

	# Mesh is centered at origin so it pivots cleanly during animation.
	var hx: float = float(w) * 0.5
	var hy: float = float(h) * 0.5
	var hz: float = THICKNESS * 0.5

	for y in range(h):
		for x in range(w):
			if not opaque[y][x]:
				continue
			# Pixel position in mesh-local coords. Image y=0 is the TOP of
			# the texture; flip so it lands at +Y in world space.
			var px: float = float(x) - hx
			var py: float = float(h - 1 - y) - hy
			# Per-pixel UV rect.
			var u0: float = float(x) / float(w)
			var v0: float = float(y) / float(h)
			var u1: float = float(x + 1) / float(w)
			var v1: float = float(y + 1) / float(h)
			# CRITICAL: side faces must sample the OPAQUE pixel's color,
			# not the transparent boundary neighbor. With NEAREST filtering,
			# UV exactly at u1=(x+1)/w rounds to texel (x+1) — the TRANSPARENT
			# neighbor — and the shader's alpha cutoff discards it. Using
			# the opaque pixel's center UV guarantees we sample the right
			# texel for all four side faces. Without this fix the side
			# faces render as near-invisible "dots" only at silhouette
			# corners that happen to land on opaque boundary texels.
			var uc: float = (float(x) + 0.5) / float(w)
			var vc: float = (float(y) + 0.5) / float(h)

			# FRONT (+Z) — always emit
			_emit_quad(
				verts,
				uvs,
				norms,
				indices,
				Vector3(px, py, hz),
				Vector3(px + 1, py, hz),
				Vector3(px + 1, py + 1, hz),
				Vector3(px, py + 1, hz),
				Vector2(u0, v1),
				Vector2(u1, v1),
				Vector2(u1, v0),
				Vector2(u0, v0),
				Vector3(0, 0, 1)
			)
			# BACK (-Z) — always emit, mirrored winding
			_emit_quad(
				verts,
				uvs,
				norms,
				indices,
				Vector3(px + 1, py, -hz),
				Vector3(px, py, -hz),
				Vector3(px, py + 1, -hz),
				Vector3(px + 1, py + 1, -hz),
				Vector2(u1, v1),
				Vector2(u0, v1),
				Vector2(u0, v0),
				Vector2(u1, v0),
				Vector3(0, 0, -1)
			)

			# Sides — only where the neighbor pixel is transparent. ALL side
			# faces sample the OPAQUE pixel's CENTER UV (uc, vc) on every
			# corner, so NEAREST filtering returns the opaque texel and the
			# alpha-cutoff doesn't discard them. Using boundary UVs (u0/u1
			# at exact pixel edges) was rounding to the transparent neighbor
			# and discarding ~all side area.
			# +X (right neighbor)
			if x == w - 1 or not opaque[y][x + 1]:
				_emit_quad(
					verts,
					uvs,
					norms,
					indices,
					Vector3(px + 1, py, hz),
					Vector3(px + 1, py, -hz),
					Vector3(px + 1, py + 1, -hz),
					Vector3(px + 1, py + 1, hz),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector3(1, 0, 0)
				)
			# -X (left neighbor)
			if x == 0 or not opaque[y][x - 1]:
				_emit_quad(
					verts,
					uvs,
					norms,
					indices,
					Vector3(px, py, -hz),
					Vector3(px, py, hz),
					Vector3(px, py + 1, hz),
					Vector3(px, py + 1, -hz),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector3(-1, 0, 0)
				)
			# +Y (image y-1, world up)
			if y == 0 or not opaque[y - 1][x]:
				_emit_quad(
					verts,
					uvs,
					norms,
					indices,
					Vector3(px, py + 1, hz),
					Vector3(px + 1, py + 1, hz),
					Vector3(px + 1, py + 1, -hz),
					Vector3(px, py + 1, -hz),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector3(0, 1, 0)
				)
			# -Y (image y+1, world down)
			if y == h - 1 or not opaque[y + 1][x]:
				_emit_quad(
					verts,
					uvs,
					norms,
					indices,
					Vector3(px, py, -hz),
					Vector3(px + 1, py, -hz),
					Vector3(px + 1, py, hz),
					Vector3(px, py, hz),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector2(uc, vc),
					Vector3(0, -1, 0)
				)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _emit_quad(
	verts: PackedVector3Array,
	uvs: PackedVector2Array,
	norms: PackedVector3Array,
	indices: PackedInt32Array,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	uv0: Vector2,
	uv1: Vector2,
	uv2: Vector2,
	uv3: Vector2,
	normal: Vector3
) -> void:
	var base: int = verts.size()
	verts.append(p0)
	verts.append(p1)
	verts.append(p2)
	verts.append(p3)
	uvs.append(uv0)
	uvs.append(uv1)
	uvs.append(uv2)
	uvs.append(uv3)
	norms.append(normal)
	norms.append(normal)
	norms.append(normal)
	norms.append(normal)
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 3)
