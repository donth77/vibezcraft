class_name ModelBox
extends RefCounted
## Alpha's ModelRenderer box (ka.java) — the textured cuboid every entity
## model in 1.2.6 is assembled from — for the models drawn from a single
## skin sheet: the minecart (im.java) and the boat (cv.java).
##
## Godot's BoxMesh cannot stand in for it. BoxMesh packs its six faces
## into a 3×2 grid of the UV square, so cropping its UVs to one skin
## region hands every face a third-by-half sliver of that region: single
## texel rows of a rim or plank seam stretched across a whole wall, which
## read as broad dark bands on the cart and stripes on the boat.
##
## Coordinates are vanilla model units (1/16 block, Y down), exactly as
## the model classes declare them; `post` carries the renderer's flip and
## scale into the entity's local space.

# ka.java:52-67 — the eight corners, bit 0 = +X, bit 1 = +Y, bit 2 = +Z
# in the order vanilla numbers them (ew2..ew9).
const _CORNER_SIGNS: Array[Vector3i] = [
	Vector3i(0, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(1, 1, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, 0, 1),
	Vector3i(1, 0, 1),
	Vector3i(1, 1, 1),
	Vector3i(0, 1, 1),
]
# ka.java:68-73 — each face's four corners, in vanilla's order: +X, -X,
# -Y, +Y, -Z, +Z. Every quad winds counter-clockwise seen from outside.
const _FACE_CORNERS: Array = [
	[5, 1, 2, 6],
	[0, 4, 7, 3],
	[5, 4, 0, 1],
	[2, 3, 7, 6],
	[1, 0, 3, 2],
	[4, 5, 6, 7],
]
# nc.java:16-17 pulls every UV 0.1 texel in from its rectangle's edge so
# nearest sampling never bleeds in the neighbouring region.
const _UV_INSET_TEXELS: float = 0.1


# Append one box to `st`. `tex` is the box's skin offset (ka's l / m),
# `from` and `size` its bounds (ka.a(...)), `pivot` its rotation point
# (ka.a(x, y, z)) and `rot` its rotation in radians (ka.d / e / f).
# ka.java:97-109 applies them as translate(pivot) · rotZ · rotY · rotX.
static func add(
	st: SurfaceTool,
	post: Transform3D,
	tex: Vector2i,
	from: Vector3,
	size: Vector3i,
	pivot: Vector3 = Vector3.ZERO,
	rot: Vector3 = Vector3.ZERO,
	tex_size: Vector2 = Vector2(64, 32)
) -> void:
	var part := Transform3D(
		(
			Basis(Vector3(0, 0, 1), rot.z)
			* Basis(Vector3(0, 1, 0), rot.y)
			* Basis(Vector3(1, 0, 0), rot.x)
		),
		pivot
	)
	var xf: Transform3D = post * part
	var corners: Array[Vector3] = []
	for corner: Vector3i in _CORNER_SIGNS:
		corners.append(xf * (from + Vector3(corner * size)))
	var rects: Array[Rect2] = face_rects(tex, size)
	var inset := Vector2(_UV_INSET_TEXELS, _UV_INSET_TEXELS) / tex_size
	for face: int in range(6):
		var r: Rect2 = rects[face]
		var u0: float = r.position.x / tex_size.x + inset.x
		var v0: float = r.position.y / tex_size.y + inset.y
		var u1: float = r.end.x / tex_size.x - inset.x
		var v1: float = r.end.y / tex_size.y - inset.y
		# nc.java:18-21 — corner 0 takes the rectangle's top-right, then
		# top-left, bottom-left, bottom-right.
		var uvs: Array[Vector2] = [
			Vector2(u1, v0), Vector2(u0, v0), Vector2(u0, v1), Vector2(u1, v1)
		]
		var quad: Array = _FACE_CORNERS[face]
		var a: Vector3 = corners[quad[0]]
		var normal: Vector3 = (corners[quad[1]] - a).cross(corners[quad[2]] - a).normalized()
		# Vanilla's quads are counter-clockwise from outside; Godot keeps
		# clockwise faces, so each quad goes down as (0,2,1) + (0,3,2).
		for k: int in [0, 2, 1, 0, 3, 2]:
			st.set_normal(normal)
			st.set_uv(uvs[k])
			st.add_vertex(corners[quad[k]])


# ka.java:68-73 — the skin rectangle (in texels) each face samples, in
# `_FACE_CORNERS` order, for a box of `size` at skin offset `tex`: the
# classic unwrap with the two d-deep caps along the top row and the four
# h-tall sides beneath them.
static func face_rects(tex: Vector2i, size: Vector3i) -> Array[Rect2]:
	var u: int = tex.x
	var v: int = tex.y
	var w: int = size.x
	var h: int = size.y
	var d: int = size.z
	var rects: Array[Rect2] = [
		Rect2(u + d + w, v + d, d, h),
		Rect2(u, v + d, d, h),
		Rect2(u + d, v, w, d),
		Rect2(u + d + w, v, w, d),
		Rect2(u + d, v + d, w, h),
		Rect2(u + d + w + d, v + d, w, h),
	]
	return rects
