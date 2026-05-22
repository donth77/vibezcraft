class_name SignNode
extends Node3D

# In-world overlay that renders a sign's 4 lines of text on top of the
# sign's panel face. Spawned by chunk_node._sync_sign_entities and
# parented under the chunk_node, positioned at the sign's local cell
# coords (cell-center in XZ, ground in Y so the post + panel mesh
# coords already in the chunk's mesh align with this node's transform).
#
# Text content comes from SignStorage keyed by world position. The
# node listens to SignStorage.text_changed and rebuilds its labels
# only when its own pos changes — cheap, no per-frame work.
#
# Stage 2C scope: 4 small Label3D children stacked vertically, oriented
# to face the panel's inscribed direction (driven by SIGN_STANDING's
# yaw meta or SIGN_WALL's direction meta). Text is white with a dark
# shadow for legibility against the planks texture.
#
# Vanilla ref: rt.java::RenderSign + qc.java::TileEntitySign. Vanilla
# uses bitmap font rendering directly to the mesh; we use Label3D
# since it gives us free font + outline handling and the labels render
# at the same depth as the panel (no z-fighting at our typical scales).

const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

# Vanilla sign panel geometry (matches mesher.gd):
#   Standing panel y ∈ [0.5, 1.0] (height 0.5, centered at 0.75).
#   Wall panel    y ∈ [0.25, 0.75] (height 0.5, centered at 0.50).
# Both panels are 0.5 tall and 0.875 wide. The 4 text lines stack
# symmetrically inside that height, centered on the panel mid-Y so
# the top line doesn't spill above the panel and the bottom line
# doesn't spill below.
# Line stack offsets are a compromise between plank-row alignment and
# panel-edge clearance. Vanilla text size (~0.089 m) is bigger than the
# 3-texel plank light area (0.094 m) - 1 texel margin, so we can't
# both center text on plank rows AND keep a top gap on wall signs.
# Half-texel shift below splits the difference: line 0 sits midway
# between plank-row center (texel 1) and seam (texel 3), so the text
# has a small top gap AND text bottom stays above the seam.
const PANEL_MID_Y_STANDING: float = 0.71875  # 0.75 - 1 texel (plank-centered)
const PANEL_MID_Y_WALL: float = 0.515625  # 0.5 + 0.5 texel (half-texel gap from panel top)
# Fence-mounted standing sign uses a SHORTER post (0.25 m) so the panel
# y range is [0.25, 0.75] (centered at 0.5) instead of [0.5, 1.0]
# (centered at 0.75). Apply the same -0.03125 plank-alignment shift.
const PANEL_MID_Y_STANDING_ON_FENCE: float = 0.46875  # 0.5 - 1 texel
# 4 lines centered in the 0.5 m panel, ONE LINE PER PLANK ROW.
# Vanilla MC's planks.png has 4 horizontal plank rows (4 texels tall
# each) with dark seams between, and vanilla sign rendering aligns
# each text line to the centre of a plank row so the dark seams sit
# between lines. Panel height 0.5 m = 16 texels → each plank row is
# 4 texels = 0.125 m tall, so LINE_HEIGHT 0.125 puts every line on
# its own plank row.
const LINE_HEIGHT: float = 0.125
# Push labels slightly off the panel face along the inscribed-face
# normal to avoid z-fighting. 1 cm is enough at our zoom levels.
const TEXT_FRONT_OFFSET: float = 0.01
# Wall sign panel center sits 0.375 m from cell center along the
# inscribed-face's OPPOSITE direction — the panel hangs on the
# support's far side. Mesher coords:
#   meta=0 (-Z face): panel z ∈ [0.875, 1.0], front face at z=0.875
#   → front face center = cell_center + (0, 0, +0.375) = cell_center - fwd * 0.375
# Same relationship for the other 3 faces.
const WALL_PANEL_FACE_OFFSET: float = 0.375
# Standing sign panel is centered XZ inside the cell; the front face
# sits half-thickness forward of the panel center.
const STANDING_PANEL_HALF_THICKNESS: float = 0.0625
const FONT_SIZE: int = 24
# Pixel size for Label3D. font_size × pixel_size = text height in m.
# 0.0034 puts text height at ~0.082 m (≈ vanilla TileEntitySign which
# renders the bitmap font at 8 px × scale 0.01111 ≈ 0.089 m per line).
# Slightly under-vanilla so we keep a ~1 texel top gap on wall signs
# (the previous 0.0036 overflowed the panel; 0.0025 was readable but
# distinctly smaller than vanilla).
const TEXT_PIXEL_SIZE: float = 0.0034

# Standing vs wall variant + meta drive the panel orientation. Set by
# chunk_node before add_child so _ready can position the labels.
var is_wall_sign: bool = false
var meta: int = 0
# Set by chunk_node when the wall sign's support cell is a fence —
# offsets the label positions to follow the mesher's panel offset (so
# the text stays on the panel rather than floating where the panel
# WOULD have been at the cell face). Zero vector when not fence-attached.
var fence_offset: Vector3 = Vector3.ZERO
# Set by chunk_node when a STANDING sign sits on top of a fence — the
# mesher renders it with a shorter post + panel y range [0.25, 0.75]
# instead of [0.5, 1.0], so the labels use the smaller PANEL_MID.
var on_fence: bool = false
# World-cell coords this sign occupies. Set by chunk_node before
# add_child; SignStorage is keyed by these coords so the signal-driven
# refresh requires an exact match. We do NOT derive this from
# global_position because Godot's `round(half)` rounds away from zero —
# `round(-0.5) = -1` rather than 0 — which used to break the match at
# cell coord 0 and any negative coord.
var world_pos: Vector3i = Vector3i.ZERO
# 4 Label3D children — built once in _ready, text mutated on refresh.
var _labels: Array[Label3D] = []


# Caller (chunk_node) sets world_pos / is_wall_sign / meta then add_child.
# We grab the font + spawn the 4 Label3Ds + connect to SignStorage.
func _ready() -> void:
	var font: Font = load(FONT_PATH) as Font
	for i in range(SignStorage.LINES_PER_SIGN):
		var label := Label3D.new()
		label.text = ""
		label.font = font
		label.font_size = FONT_SIZE
		label.pixel_size = TEXT_PIXEL_SIZE
		label.modulate = Color.BLACK
		label.outline_modulate = Color(0, 0, 0, 0)  # no outline — keeps it readable
		label.no_depth_test = false
		label.shaded = false
		# Pixel-perfect glyph sampling. Minecraft.otf's .import is already
		# antialiasing=0 + hinting=0, so the rasterized glyph atlas has
		# hard pixel edges; Label3D's default LINEAR filter then blurred
		# those edges when scaling up to the panel size. NEAREST keeps
		# the chunky-pixel look that matches vanilla's bitmap font.
		label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		# Render both sides — players can walk around standing signs and
		# read from the back, and our wall-sign normal pick is conservative.
		# Vanilla also renders both sides (the text mesh is double-sided).
		label.double_sided = true
		# Vanilla sign text is centered on each line.
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(label)
		_labels.append(label)
	_layout_labels()
	_refresh_text()
	SignStorage.text_changed.connect(_on_text_changed)


# Compute the per-line transform inside this node's local space. The
# node sits at cell-center (XZ) + cell-base (Y), so panel-relative
# coords are simple offsets.
func _layout_labels() -> void:
	if is_wall_sign:
		_layout_wall_labels()
	else:
		_layout_standing_labels()


# Stack the 4 line centers symmetrically around `mid_y`. With 4 lines
# at LINE_HEIGHT spacing, line i's center sits at mid_y + (1.5 - i) * H.
# So lines fall at mid_y + 0.15, +0.05, -0.05, -0.15 (top → bottom).
static func _line_y(mid_y: float, i: int) -> float:
	return mid_y + (1.5 - float(i)) * LINE_HEIGHT


# Standing sign: 4 lines stacked on the rotated panel front face.
# Panel rotates around the cell-center Y axis by yaw_rad.
func _layout_standing_labels() -> void:
	var yaw_rad: float = float(meta) * (TAU / 16.0)
	# Forward = panel's inscribed-face normal. Same math as the mesher's
	# n_front = (-sin(yaw), 0, cos(yaw)).
	var fwd := Vector3(-sin(yaw_rad), 0.0, cos(yaw_rad))
	# Godot's Basis.rotated(UP, +θ) rotates OPPOSITE to the mesher's panel
	# formula (rx = sx·cos − sz·sin, rz = sx·sin + sz·cos):
	#   Godot:  +Z rotates to +X by +π/2
	#   Mesher: +X rotates to +Z by +π/2   (same direction in panel-local)
	# So a label rotated by +yaw_rad ends up facing the BACK of the panel
	# for any meta where sin(yaw) ≠ 0. Negate yaw_rad to match the panel.
	var basis := Basis.IDENTITY.rotated(Vector3.UP, -yaw_rad)
	# Panel front face center in cell-local: (0.5, 0.75, 0.5) + fwd * 0.0625
	# (half-thickness). Push 1 cm further along fwd to clear z-fighting.
	var face_offset: float = STANDING_PANEL_HALF_THICKNESS + TEXT_FRONT_OFFSET
	# Fence-mounted standing signs have a shorter post so the panel sits
	# lower; pick the matching PANEL_MID so labels follow the panel.
	var panel_mid: float = PANEL_MID_Y_STANDING_ON_FENCE if on_fence else PANEL_MID_Y_STANDING
	for i in range(SignStorage.LINES_PER_SIGN):
		var label: Label3D = _labels[i]
		var y: float = _line_y(panel_mid, i)
		label.position = Vector3(0.5, y, 0.5) + fwd * face_offset
		label.basis = basis


# Wall sign: 4 lines stacked on the axis-aligned panel face whose
# direction is encoded in meta (0..3 → -Z / +Z / -X / +X). The panel
# hangs on the SUPPORT block's far side (opposite of fwd) and faces
# back along fwd toward the player. So the panel's front face center
# sits at cell_center - fwd * WALL_PANEL_FACE_OFFSET — NOT + fwd, which
# would put labels on the empty side of the cell (the old "floating
# in air" bug).
func _layout_wall_labels() -> void:
	var fwd: Vector3
	var yaw_rad: float
	match meta:
		0:  # -Z face
			fwd = Vector3(0, 0, -1)
			yaw_rad = PI
		1:  # +Z face
			fwd = Vector3(0, 0, 1)
			yaw_rad = 0.0
		2:  # -X face
			fwd = Vector3(-1, 0, 0)
			yaw_rad = PI / 2.0
		_:  # +X face (meta 3)
			fwd = Vector3(1, 0, 0)
			yaw_rad = -PI / 2.0
	var cell_center := Vector3(0.5, 0.5, 0.5)
	var panel_face_center: Vector3 = cell_center - fwd * WALL_PANEL_FACE_OFFSET
	# Same handedness mismatch as standing signs — see _layout_standing_labels.
	# For meta 2 / 3 (X-axis faces) this difference flips the label across
	# the panel, so the text reads back-to-front.
	var basis := Basis.IDENTITY.rotated(Vector3.UP, -yaw_rad)
	for i in range(SignStorage.LINES_PER_SIGN):
		var label: Label3D = _labels[i]
		var y: float = _line_y(PANEL_MID_Y_WALL, i)
		# Apply the same fence_offset the mesher applied to the panel
		# so labels stay on the panel face when the wall sign is mounted
		# on a fence (panel offset 0.375 m into the support cell).
		label.position = (
			Vector3(panel_face_center.x, y, panel_face_center.z)
			+ fwd * TEXT_FRONT_OFFSET
			+ fence_offset
		)
		label.basis = basis


func _refresh_text() -> void:
	var lines: Array = SignStorage.get_lines(world_pos)
	for i in range(SignStorage.LINES_PER_SIGN):
		_labels[i].text = String(lines[i])


# Listen for changes anywhere; only refresh if it's OUR position.
func _on_text_changed(pos: Vector3i) -> void:
	if pos == world_pos:
		_refresh_text()


# chunk_node calls this when the sign block is replaced (e.g. broken +
# re-placed with a different meta/orientation in the same cell). We
# re-run the layout so the labels follow the new orientation.
func update_orientation(new_is_wall: bool, new_meta: int) -> void:
	if is_wall_sign == new_is_wall and meta == new_meta:
		return
	is_wall_sign = new_is_wall
	meta = new_meta
	_layout_labels()
