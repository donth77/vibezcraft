class_name CharacterPreview
extends TextureRect

# LIVE preview of the player avatar in the inventory. An offscreen
# SubViewport (built once at boot, parented to the Game autoload) renders
# the character_model continuously via UPDATE_ALWAYS; this TextureRect
# displays viewport.get_texture() directly so any mutation of the model
# (future armor equip, head tracking, animation) auto-reflects without
# any per-frame work in this script.
#
# Other code can grab the model via CharacterPreview.get_model() to mutate
# it (e.g. attach an armor mesh, set head rotation).

const PREVIEW_PX: int = 256

static var _viewport: SubViewport
static var _model: Node3D


func _ready() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _viewport != null:
		# Live ViewportTexture binding — auto-updates as the viewport renders.
		texture = _viewport.get_texture()


# Build the offscreen viewport + character model. Call once at boot from
# Game._ready (or any node living in the persistent scene tree).
static func setup_renderer(parent: Node) -> void:
	if _viewport != null:
		return
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(PREVIEW_PX, PREVIEW_PX)
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	# Only render when the inventory's TextureRect is actually drawn (i.e.,
	# when the inventory screen is open). Saves a 256² render every frame
	# while the player is just walking around with the inventory closed.
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	parent.add_child(_viewport)
	# Explicit World3D — own_world_3d=true was leaving world_3d null and the
	# camera/lights/model were rendering into a non-existent world.
	_viewport.world_3d = World3D.new()

	# Front-facing orthographic camera. Model defaults face -Z; camera at -Z
	# looking at +Z sees Steve's front. y=0.1 is the model's vertical center.
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.4  # 2-unit-tall model + ~20% padding
	camera.near = 0.05
	camera.far = 10.0
	_viewport.add_child(camera)
	# look_at_from_position avoids the "Node not inside tree" error when the
	# transform is being assigned during the same frame the viewport is set up.
	camera.look_at_from_position(Vector3(0, 0.1, -4.0), Vector3(0, 0.1, 0), Vector3.UP)

	# Ambient WorldEnvironment so directional lights aren't the sole source
	# of illumination — lets the model show up reliably regardless of pose.
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_viewport.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.6
	_viewport.add_child(sun)
	sun.look_at_from_position(Vector3(1.0, 2.0, -2.0), Vector3.ZERO, Vector3.UP)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.5
	_viewport.add_child(fill)
	fill.look_at_from_position(Vector3(-1.0, 0.5, -1.0), Vector3.ZERO, Vector3.UP)

	var model_script: GDScript = load("res://scripts/player/character_model.gd")
	if model_script == null:
		push_error("[CharPreview] failed to load character_model.gd")
		return
	_model = model_script.new()
	_viewport.add_child(_model)
	# Keep materials unshaded so the preview is robust to lighting tweaks.
	_force_unshaded(_model)


# Returns the live model node so other code can mutate it (attach armor
# meshes to limb anchors, rotate head, drive walking animation, etc.).
static func get_model() -> Node3D:
	return _model


# Recursively walk a node tree and override every MeshInstance3D's material
# with an unshaded clone. Skin texture (albedo) is preserved.
static func _force_unshaded(node: Node) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		if mi.mesh != null and mi.mesh.get_surface_count() > 0:
			var orig: Material = mi.mesh.surface_get_material(0)
			if orig is StandardMaterial3D:
				var unshaded: StandardMaterial3D = (orig as StandardMaterial3D).duplicate()
				unshaded.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
				mi.material_override = unshaded
	for child in node.get_children():
		_force_unshaded(child)
