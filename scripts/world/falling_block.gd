class_name FallingBlock
extends Node3D

# Vanilla MC's EntityFallingBlock — visible falling animation for gravel
# / sand. Spawned by ChunkManager._settle_gravity_above when a gravity
# block becomes unsupported. Falls under constant gravity, raycasts down
# each frame to detect the landing surface, then writes itself back as a
# real block at the landing y and despawns.

const GRAVITY: float = -16.0  # vanilla EntityFallingBlock: motY -= 0.04/tick @ 20 TPS
const TERMINAL_VELOCITY: float = -32.0
const MESH_SIZE: float = 0.999  # tiny inset so raycasts don't self-collide
const SAFETY_LIFETIME_SEC: float = 6.0  # despawn fallback if something goes wrong

var block_id: int = 0
var _velocity_y: float = 0.0
var _spawn_time: float = 0.0
var _ray_query: PhysicsRayQueryParameters3D
var _chunk_manager: Node
var _mesh: MeshInstance3D
var _last_light_brightness: float = -1.0


# Vanilla BlockSand.canFallBelow: a falling block passes through air,
# fire, and liquids ONLY — torches, plants, and every other non-cube
# still stop the fall (sand rests on a torch in Alpha). Landing inside
# a liquid column replaces the bottom liquid cell (sand sinks to the
# pond floor). The previous `!= AIR` test treated water as a landing
# surface, so sand hovered on the surface while the gravity trigger
# treated the same water as no-support — "water as both air and a
# block". Public: ChunkManager's gravity triggers use the SAME
# predicate, so a block only starts falling when this entity can
# actually descend (is_replaceable was too wide — saplings are
# replaceable but stop a fall, which spawn/land-looped).
static func is_passable_for_fall(id: int) -> bool:
	return id == Blocks.AIR or id == Blocks.FIRE or Blocks.is_fluid(id)


func setup(p_block_id: int) -> void:
	block_id = p_block_id
	_spawn_time = Time.get_ticks_msec() / 1000.0
	_mesh = MeshInstance3D.new()
	_mesh.mesh = BlockMesh.get_cube_mesh(p_block_id, MESH_SIZE)
	_mesh.material_override = BlockAtlas.entity_material()
	add_child(_mesh)
	_ray_query = PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	# Vanilla EntityFallingBlock.move() does AABB collision against *blocks
	# only* — entities don't shove each other, so the falling block falls
	# straight through the player and lands on the terrain below. Our ray
	# hits every collider in its path including the player's CharacterBody3D,
	# which would land the block on the player's head. Exclude the player's
	# RID so the ray sees only terrain (and only terrain can be landed on).
	var player: CharacterBody3D = get_tree().root.get_node_or_null("Main/Player") as CharacterBody3D
	if player != null:
		_ray_query.exclude = [player.get_rid()]
	_update_entity_lighting()


func _process(delta: float) -> void:
	if _chunk_manager == null:
		queue_free()
		return
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _spawn_time
	if elapsed > SAFETY_LIFETIME_SEC:
		_land_at(int(floor(global_position.y)))
		return
	_update_entity_lighting()

	var x: int = int(floor(global_position.x))
	var z: int = int(floor(global_position.z))
	# Stacked-column defense: when a column of sand/gravel falls together,
	# entities land one at a time — but the entity above has its mesh
	# extending into the cell that just became solid, and renders a z-
	# fighting overlap for the frame between its neighbour landing and
	# its own descent. Check every frame whether the cell our mesh bottom
	# is currently in became solid; if so, land on top of it immediately.
	var bottom_cell_y: int = int(floor(global_position.y - MESH_SIZE * 0.5))
	if not is_passable_for_fall(_chunk_manager.get_world_block(Vector3i(x, bottom_cell_y, z))):
		_land_at(bottom_cell_y + 1)
		return

	_velocity_y = maxf(_velocity_y + GRAVITY * delta, TERMINAL_VELOCITY)
	var step: float = _velocity_y * delta
	var new_y: float = global_position.y + step
	# Sweep DOWN through integer cells from current bottom to destination
	# bottom, checking chunk data directly instead of physics raycasting.
	# A TNT blast on sand can spawn 100+ FallingBlocks at once; physics
	# raycasts at that count drop the frame rate by 40+ FPS. Direct
	# chunk_manager.get_world_block calls are ~10× cheaper and give the
	# same accuracy at single-cell granularity (sand falls cell-by-cell).
	var new_bottom_y: int = int(floor(new_y - MESH_SIZE * 0.5))
	if new_bottom_y < bottom_cell_y:
		# Walk down through the cells we'd cross this frame.
		for check_y in range(bottom_cell_y - 1, new_bottom_y - 1, -1):
			if not is_passable_for_fall(_chunk_manager.get_world_block(Vector3i(x, check_y, z))):
				_land_at(check_y + 1)
				return
	global_position.y = new_y
	if new_y < -10.0:
		# Fell off the world; just disappear.
		queue_free()


func _update_entity_lighting() -> void:
	if _mesh == null or _chunk_manager == null:
		return
	var cell := Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var brightness: float = EntityLighting.sample_brightness(_chunk_manager, cell)
	if absf(brightness - _last_light_brightness) < 0.01:
		return
	_last_light_brightness = brightness
	_mesh.set_instance_shader_parameter("entity_brightness", brightness)


# Place the block at the landing cell, but if that cell isn't passable
# (player raced us by placing something), settle on top instead. Cascades
# up while the target is occupied so we never overwrite a real block —
# fluids/fire ARE overwritten, which is how sand lands on a pond floor
# (the displaced water just vanishes, vanilla-style; neighbors re-flow
# via the fluid notify in set_world_block).
func _land_at(land_y: int) -> void:
	var x: int = int(floor(global_position.x))
	var z: int = int(floor(global_position.z))
	while land_y < 128:
		var pos := Vector3i(x, land_y, z)
		if is_passable_for_fall(_chunk_manager.get_world_block(pos)):
			# `_immediate` forces the chunk to remesh this frame so the
			# landed block is drawn on the same frame we hide the entity
			# below. Without it, the entity vanishes first and the block
			# appears one frame later — a visible pop.
			_chunk_manager.set_world_block_immediate(pos, block_id)
			break
		land_y += 1
	# Hide before queue_free so we don't render one last frame at a pose
	# that might overlap freshly placed geometry (queue_free is deferred
	# to end-of-frame; visibility takes effect immediately).
	visible = false
	queue_free()
