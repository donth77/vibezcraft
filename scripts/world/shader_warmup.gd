class_name ShaderWarmup
extends Node3D

# One-frame draw of every lazily-compiled material, parented to the player
# camera while the loading screen still covers the viewport. WebGL2/ANGLE
# compiles+links a GL program synchronously at a material's FIRST DRAW —
# 50-300 ms per program — so without this pass those compile stalls land
# mid-gameplay: first block break (crack shader + break-particle
# material), first dropped item (entity + extruded-item shaders), first
# tool/block equip (held-item + overlay shaders). Desktop GL drivers hide
# the same compiles well enough that none of this was visible before the
# web port; the warm pass costs a handful of tiny quads for 8 frames, so
# it runs on every platform rather than web-gating.

const _LIFETIME_FRAMES: int = 8

var _frames: int = 0


func _ready() -> void:
	# crack.gdshader draws on ordinary chunk geometry — a quad's vertex
	# format is representative, so keep it on the cheap quad path.
	var crack_mat := ShaderMaterial.new()
	crack_mat.shader = load("res://shaders/crack.gdshader") as Shader
	_add_warm_mesh(crack_mat, _make_quad())
	# held_item / held_item_world draw a SpriteExtruder ArrayMesh, whose
	# vertex format differs from a QuadMesh — and GLES3 (the web renderer)
	# compiles a SEPARATE program per vertex format. Warming these with a
	# quad left the REAL extruded-mesh variant to compile on the first
	# item equip: a barely-visible hitch on desktop, a 1-2 s freeze on a
	# slow mobile GPU (issue #5 "scrolling onto sugarcane freezes"). Warm
	# them with an actual tiny extruded mesh + a bound item_texture so the
	# exact program is ready before the first hold.
	var warm_tex: Texture2D = _make_warm_item_texture()
	var warm_mesh: ArrayMesh = SpriteExtruder.build(warm_tex)
	for path: String in [
		"res://shaders/held_item.gdshader", "res://shaders/held_item_world.gdshader"
	]:
		var mat := ShaderMaterial.new()
		mat.shader = load(path) as Shader
		mat.set_shader_parameter("item_texture", warm_tex)
		mat.render_priority = 100
		_add_warm_mesh(mat, warm_mesh)
	# Shared block materials — the first dropped item / falling block /
	# first-person held block would otherwise compile these mid-gameplay.
	_add_warm_quad(BlockAtlas.entity_material())
	_add_warm_quad(BlockAtlas.overlay_material())
	# Water + lava surface shaders — an inland spawn compiles these the
	# first time a lake/lava pool scrolls into view (a one-off 50-300 ms
	# WebGL2 stall mid-walk). Warm quads use the same shared materials.
	_add_warm_quad(BlockAtlas.water_material())
	_add_warm_quad(BlockAtlas.lava_material())
	# Mob materials — both StandardMaterial3D program variants mobs use
	# (opaque unshaded + alpha-scissor). These are the SHARED cached
	# instances, so the warm draw compiles the exact programs the first
	# on-screen pig / skeleton would otherwise stall on. The spatial
	# feature bits (not the texture) select the GL program, so two
	# variants cover every species.
	_add_warm_quad(MobBase.get_shared_material("res://assets/textures/mob/pig.png"))
	_add_warm_quad(MobBase.get_shared_material("res://assets/textures/mob/pig.png", true))


func _process(_delta: float) -> void:
	if _frames == 0:
		# One real break burst compiles the CPUParticles pipeline +
		# particle StandardMaterial variant. Runs on the first process
		# frame, NOT in _ready: during the boot _ready chain the scene
		# root is still "busy setting up children" and BlockFx._acquire's
		# add_child on it fails (emitter never enters the tree, nothing
		# warms). Parented to the SCENE, not this self-freeing node — the
		# pool's return-timer lambda captures the emitter, and freeing it
		# with the warmup would log "Lambda capture was freed" and evict
		# the warmed emitter from the pool. Hidden behind the loading UI.
		var scene_root: Node = get_tree().current_scene
		if scene_root != null:
			# BlockFx samples voxel lighting from its parent. The scene root
			# owns no light-query API, so pass the real manager just as
			# gameplay break bursts do. Falling back keeps isolated shader
			# preview scenes functional without turning warmup into an error.
			var manager: Node = scene_root.get_node_or_null("ChunkManager")
			BlockFx.spawn_break(
				manager if manager != null else scene_root,
				Vector3i(global_position.floor()),
				Blocks.STONE
			)
	_frames += 1
	if _frames >= _LIFETIME_FRAMES:
		queue_free()


func _add_warm_quad(mat: Material) -> void:
	_add_warm_mesh(mat, _make_quad())


func _make_quad() -> Mesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	return quad


# Tiny RGBA texture with a couple of opaque pixels — enough for
# SpriteExtruder to emit a real extruded ArrayMesh (the vertex FORMAT,
# which selects the GL program, is independent of pixel content).
func _make_warm_item_texture() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.set_pixel(1, 1, Color(1, 0, 0, 1))
	img.set_pixel(2, 2, Color(0, 1, 0, 1))
	return ImageTexture.create_from_image(img)


func _add_warm_mesh(mat: Material, mesh: Mesh) -> void:
	if mat == null or mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	# Inside the frustum on purpose — GL only compiles at an actual draw,
	# so a frustum-culled mesh warms nothing. The loading UI hides it.
	mi.position = Vector3(0, 0, -0.5)
	add_child(mi)
