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

# Vanilla sign-text proportions — 4 lines fit in ~0.4 m of vertical
# panel space (panel is 0.5 tall, with margin top + bottom). Per-line
# height = 0.1 m; font size scales accordingly.
const LINE_HEIGHT: float = 0.1
# Text panel sits this far above the cell base. Aligns with the panel
# top half (panel y=0.5..1.0 for standing, y=0.25..0.75 for wall).
const TEXT_BASE_Y_STANDING: float = 0.55
const TEXT_BASE_Y_WALL: float = 0.30
# Panel front face offset from the post center / wall face. Matches
# mesher.gd's panel coords — push slightly forward so the labels don't
# z-fight with the panel quad.
const TEXT_FRONT_OFFSET: float = 0.07
const FONT_SIZE: int = 24
# Pixel size for Label3D — 0.005 keeps the rendered text roughly
# 0.025 m tall per FONT_SIZE px, which fits 15 chars across a 0.875 m
# wide panel.
const TEXT_PIXEL_SIZE: float = 0.005

# Standing vs wall variant + meta drive the panel orientation. Set by
# chunk_node before add_child so _ready can position the labels.
var is_wall_sign: bool = false
var meta: int = 0
var _world_pos: Vector3i = Vector3i.ZERO
# 4 Label3D children — built once in _ready, text mutated on refresh.
var _labels: Array[Label3D] = []


# Caller (chunk_node) sets pos / is_wall_sign / meta then add_child.
# We grab the font + spawn the 4 Label3Ds + connect to SignStorage.
func _ready() -> void:
	_world_pos = Vector3i(
		int(round(global_position.x - 0.5)),
		int(round(global_position.y)),
		int(round(global_position.z - 0.5))
	)
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
		label.double_sided = false
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


# Standing sign: 4 lines stacked on the rotated panel front face.
# Panel rotates around the cell-center Y axis by yaw_rad.
func _layout_standing_labels() -> void:
	var yaw_rad: float = float(meta) * (TAU / 16.0)
	# Forward = panel's inscribed-face normal. Same math as the mesher's
	# n_front = (-sin(yaw), 0, cos(yaw)).
	var fwd := Vector3(-sin(yaw_rad), 0.0, cos(yaw_rad))
	var basis := Basis.IDENTITY.rotated(Vector3.UP, yaw_rad)
	for i in range(SignStorage.LINES_PER_SIGN):
		var label: Label3D = _labels[i]
		# Stack lines from the top of the panel down. Center of line i:
		# (panel_top - LINE_HEIGHT * (i + 0.5)).
		var y: float = TEXT_BASE_Y_STANDING + 0.5 - LINE_HEIGHT * (float(i) + 0.5)
		# Center XZ + forward offset to sit just in front of the panel.
		var pos: Vector3 = Vector3(0.5, y, 0.5) + fwd * TEXT_FRONT_OFFSET
		label.position = pos
		label.basis = basis


# Wall sign: 4 lines stacked on the axis-aligned panel face whose
# direction is encoded in meta (0..3 → -Z / +Z / -X / +X).
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
	# Wall sign panel center matches the cell face midpoint at y 0.5
	# (mesher emits panel at y=0.25..0.75); panel face sits at the
	# clicked face's outward side, so labels go offset by TEXT_FRONT_OFFSET.
	var cell_center := Vector3(0.5, 0.5, 0.5)
	# Push the cell_center toward the panel face: cell_center + fwd * 0.4375
	# (half-cell minus a bit) puts us right at the panel front.
	var panel_anchor: Vector3 = cell_center + fwd * 0.4375
	var basis := Basis.IDENTITY.rotated(Vector3.UP, yaw_rad)
	for i in range(SignStorage.LINES_PER_SIGN):
		var label: Label3D = _labels[i]
		# Stack from panel top down; wall panel is centered y=0.5, height 0.5.
		var y: float = TEXT_BASE_Y_WALL + 0.5 - LINE_HEIGHT * (float(i) + 0.5)
		label.position = Vector3(panel_anchor.x, y, panel_anchor.z) + fwd * 0.01
		label.basis = basis


func _refresh_text() -> void:
	var lines: Array = SignStorage.get_lines(_world_pos)
	for i in range(SignStorage.LINES_PER_SIGN):
		_labels[i].text = String(lines[i])


# Listen for changes anywhere; only refresh if it's OUR position.
func _on_text_changed(pos: Vector3i) -> void:
	if pos == _world_pos:
		_refresh_text()
