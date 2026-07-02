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
const _WARM_SHADERS: Array[String] = [
	"res://shaders/crack.gdshader",
	"res://shaders/held_item.gdshader",
	"res://shaders/held_item_world.gdshader",
]

var _frames: int = 0


func _ready() -> void:
	for path: String in _WARM_SHADERS:
		var mat := ShaderMaterial.new()
		mat.shader = load(path) as Shader
		_add_warm_quad(mat)
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
			BlockFx.spawn_break(scene_root, Vector3i(global_position.floor()), Blocks.STONE)
	_frames += 1
	if _frames >= _LIFETIME_FRAMES:
		queue_free()


func _add_warm_quad(mat: Material) -> void:
	if mat == null:
		return
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	mi.mesh = quad
	mi.material_override = mat
	# Inside the frustum on purpose — GL only compiles at an actual draw,
	# so a frustum-culled mesh warms nothing. The loading UI hides it.
	mi.position = Vector3(0, 0, -0.5)
	add_child(mi)
