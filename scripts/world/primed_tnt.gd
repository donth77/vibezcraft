class_name PrimedTNT
extends Node3D

# Vanilla Alpha 1.2.6 EntityTNTPrimed (kr.java) port. Spawned at the cell
# of an ignited TNT block (player flint-and-steel right-click, fire
# adjacency, or chain reaction from another explosion). Falls under
# gravity, ticks down a fuse, and detonates when the fuse hits zero.
#
# Vanilla constants (kr.java):
#   * default fuse = 80 ticks (4 seconds at 20 TPS)
#   * gravity = -0.04 vy/tick → at 20 TPS = -0.8 vy/sec → -16 m/s² as
#     continuous-time gravity (matches FallingBlock — same physics tuning).
#   * drag = 0.98 per tick → 0.98^20 ≈ 0.668 per second (continuous
#     equivalent: vel × pow(0.98, 20×dt))
#   * ground bounce = vh × 0.7, vy × -0.5 on collision
#   * spawn impulse = (-0.02 × cos(angle), 0.2, -0.02 × sin(angle)) per
#     kr.java:18-21 — small horizontal jitter + small upward kick so
#     stacks of TNT don't all sit perfectly stationary while ticking down.
#
# Visual: cube mesh with the TNT atlas tiles + a slightly-larger white
# overlay cube that pulses visibility during the last second of the fuse.
# Vanilla EntityRendererTNTPrimed (dm.java in Alpha) toggles the block
# between normal rendering and fullbright-white rendering every ~5 ticks
# during the last second — the iconic "TNT block flashing white" tell
# before detonation. We reproduce it with a second MeshInstance3D using
# an unshaded white StandardMaterial3D, toggled at 4 Hz during the last
# second of the fuse. Cheap (one extra mesh per primed entity), avoids
# needing a per-mesh tint uniform on the chunk shader.

const _DEFAULT_FUSE_SEC: float = 4.0  # 80 ticks at 20 TPS
const _GRAVITY: float = -16.0  # vanilla 0.04/tick² × 20² tps = 16 m/s²
const _SPAWN_VERTICAL_KICK: float = 4.0  # 0.2 vy/tick × 20 tps = 4.0 m/s
const _SPAWN_HORIZONTAL_KICK: float = 0.4  # 0.02/tick × 20 tps
# `pow(0.98, 20)` ≈ 0.668 — equivalent per-second drag factor. We apply
# it as `vel *= pow(0.98, 20 × delta)` so the math stays frame-rate-
# independent and matches vanilla at 20 TPS.
const _DRAG_PER_TICK: float = 0.98
const _BOUNCE_HORIZONTAL: float = 0.7
const _BOUNCE_VERTICAL: float = -0.5
const _MESH_SIZE: float = 0.98
const _EXPLOSION_POWER: float = 4.0
# White-flash overlay during the last second — pulses on/off at 4 Hz so
# the player sees ~4 flashes in the final second. Matches vanilla's
# 5-tick toggle pattern (5 ticks = 0.25 s = 4 Hz).
const _FLASH_HZ: float = 4.0
# Overlay scaled 1.005× the body mesh so it fully covers without
# z-fighting. Larger than that and the white extends past the silhouette
# at oblique angles; smaller and z-fighting shows through.
const _FLASH_SCALE: float = 1.005

var _fuse_remaining: float = _DEFAULT_FUSE_SEC
var _velocity: Vector3 = Vector3.ZERO
var _chunk_manager: Node
var _ray_query: PhysicsRayQueryParameters3D
var _mesh: MeshInstance3D
# White-flash overlay child — see file-level comment. Created in setup()
# alongside the body mesh; visibility pulsed in _apply_visual_flash.
var _flash_mesh: MeshInstance3D


# fuse_seconds: optional override. Chain-reaction primings pass a
# shorter fuse (0.5–1.5 s) per Alpha v.java::c(). Player ignitions and
# fire-adjacency-ignitions get the default 4 seconds.
func setup(fuse_seconds: float = _DEFAULT_FUSE_SEC) -> void:
	_fuse_remaining = fuse_seconds
	_mesh = MeshInstance3D.new()
	_mesh.mesh = BlockMesh.get_cube_mesh(Blocks.TNT, _MESH_SIZE)
	add_child(_mesh)
	# White-flash overlay — slightly larger cube with an unshaded white
	# material that obscures the body mesh during flash frames. Hidden
	# until the last second of the fuse (_apply_visual_flash toggles it).
	_flash_mesh = MeshInstance3D.new()
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * _MESH_SIZE * _FLASH_SCALE
	_flash_mesh.mesh = cube
	var white_mat := StandardMaterial3D.new()
	white_mat.albedo_color = Color.WHITE
	white_mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	_flash_mesh.material_override = white_mat
	_flash_mesh.visible = false
	add_child(_flash_mesh)
	# Spawn impulse — small horizontal jitter so stacked primed TNTs
	# don't stay perfectly aligned during their fuse, plus an upward
	# kick that lifts the entity out of its origin cell. Vanilla
	# kr.java:18-21 uses an unbiased random angle.
	var angle: float = randf() * TAU
	var kx: float = -cos(angle) * _SPAWN_HORIZONTAL_KICK
	var kz: float = -sin(angle) * _SPAWN_HORIZONTAL_KICK
	# Cancel horizontal kick components that point at a solid neighbor —
	# the entity has no horizontal collision detection (only a downward
	# raycast in _apply_physics), so without this the cube visibly clips
	# through an adjacent wall for the brief moment before gravity pulls
	# it back. Checked against the cell IN the kick direction at the
	# spawn cell's Y level.
	if _chunk_manager != null:
		var cx: int = int(floor(global_position.x))
		var cy: int = int(floor(global_position.y))
		var cz: int = int(floor(global_position.z))
		if kx > 0.0 and _chunk_manager.get_world_block(Vector3i(cx + 1, cy, cz)) != Blocks.AIR:
			kx = 0.0
		elif kx < 0.0 and _chunk_manager.get_world_block(Vector3i(cx - 1, cy, cz)) != Blocks.AIR:
			kx = 0.0
		if kz > 0.0 and _chunk_manager.get_world_block(Vector3i(cx, cy, cz + 1)) != Blocks.AIR:
			kz = 0.0
		elif kz < 0.0 and _chunk_manager.get_world_block(Vector3i(cx, cy, cz - 1)) != Blocks.AIR:
			kz = 0.0
	_velocity = Vector3(kx, _SPAWN_VERTICAL_KICK, kz)


func _ready() -> void:
	# Initialize ray query here so it exists even when callers add the
	# entity to the tree BEFORE calling setup() (e.g. fire auto-prime in
	# block_fire.gd). _ready runs at add_child time and used to crash when
	# the player-exclude line below ran against a null _ray_query.
	_ray_query = PhysicsRayQueryParameters3D.new()
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	# Exclude the player from the ground-collision raycast so we land on
	# terrain even if the player is standing on the spawn cell. Same trick
	# FallingBlock uses.
	var player: CharacterBody3D = get_tree().root.get_node_or_null("Main/Player") as CharacterBody3D
	if player != null:
		_ray_query.exclude = [player.get_rid()]
	# Fuse SFX at spawn. Volume gets quieter for chain-reaction primings
	# so a 9-block stack doesn't lay 9 simultaneous full-volume hisses
	# on top of the explosion's own boom.
	var loud: bool = _fuse_remaining >= _DEFAULT_FUSE_SEC * 0.5
	SFX.play_fuse(loud)


func _process(delta: float) -> void:
	if _chunk_manager == null:
		queue_free()
		return
	_fuse_remaining -= delta
	if _fuse_remaining <= 0.0:
		_detonate()
		return
	_apply_physics(delta)
	_apply_visual_flash()
	# Smoke disabled — could never get the particles to render correctly
	# (squished sprite look on TNT/fire smoke even via lava-fizz pool
	# path). Vanilla kr.java:51 emits one smoke per tick from entity
	# center+0.5y; revisit when a dedicated emitter looks right.


func _apply_physics(delta: float) -> void:
	# Gravity + per-tick drag (raised to dt-scaled exponent so the math
	# matches vanilla at 20 TPS regardless of our actual frame rate).
	_velocity.y += _GRAVITY * delta
	var drag: float = pow(_DRAG_PER_TICK, 20.0 * delta)
	_velocity *= drag
	# Ground collision via downward raycast — same pattern as FallingBlock.
	# When falling, check if the cell our base is in becomes solid; if so,
	# bounce instead of sinking through.
	var step: Vector3 = _velocity * delta
	var new_pos: Vector3 = global_position + step
	var bx: int = int(floor(new_pos.x))
	var by: int = int(floor(new_pos.y - _MESH_SIZE * 0.5))
	var bz: int = int(floor(new_pos.z))
	var below: int = _chunk_manager.get_world_block(Vector3i(bx, by, bz))
	if below != Blocks.AIR and _velocity.y < 0.0:
		# Snap to top of the block we'd have entered, then bounce.
		new_pos.y = float(by) + 1.0 + _MESH_SIZE * 0.5
		_velocity.x *= _BOUNCE_HORIZONTAL
		_velocity.z *= _BOUNCE_HORIZONTAL
		_velocity.y *= _BOUNCE_VERTICAL
		# Tiny velocities bouncing forever cause the entity to jiggle
		# in place — clamp to zero below threshold so it sits still.
		if absf(_velocity.y) < 0.5:
			_velocity.y = 0.0
	global_position = new_pos
	# Safety: if we somehow fell out of the world, just despawn instead
	# of leaving an orphan ticker running.
	if global_position.y < -16.0:
		queue_free()


# White-flash overlay pulse during the last second of the fuse. Vanilla
# EntityRendererTNTPrimed toggles the cube between normal rendering and
# fullbright-white every 5 ticks (4 Hz at 20 TPS) during the final
# second — the iconic "TNT block flashing white" tell before detonation.
# We pulse the overlay's visibility on a sine-derived square wave.
func _apply_visual_flash() -> void:
	if _flash_mesh == null:
		return
	if _fuse_remaining > 1.0:
		_flash_mesh.visible = false
		return
	# Square wave: visible when sin(...) > 0. Frequency 4 Hz so the player
	# sees ~4 on/off cycles during the last second, matching vanilla's
	# 5-tick toggle pattern at 20 TPS.
	var flash_t: float = _DEFAULT_FUSE_SEC - _fuse_remaining
	_flash_mesh.visible = sin(flash_t * TAU * _FLASH_HZ) > 0.0


func _detonate() -> void:
	# Hide the visual mesh BEFORE triggering the explosion so the cube
	# doesn't render one last frame inside the blast cloud (queue_free
	# is deferred to end-of-frame). The explosion itself runs on this
	# stack; we queue_free on return so the entity is alive as the
	# blast's `source` (lets future entity-damage code skip self-damage).
	visible = false
	Explosion.detonate(_chunk_manager, global_position, _EXPLOSION_POWER, self)
	queue_free()
