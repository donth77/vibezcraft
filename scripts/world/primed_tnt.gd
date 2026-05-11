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
# Visual: cube mesh with the TNT atlas tiles. Vanilla also pulses the
# tint between full-bright and unlit at ~10 Hz during the last second
# of fuse to telegraph imminence — we approximate with a scale wobble
# so the cube appears to "breathe" since our shader doesn't expose a
# per-mesh emissive uniform.

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
# Scale wobble during last second — purely visual, vanilla's flash effect
# isn't reproducible without a tinted shader uniform on the cube material.
const _WOBBLE_AMP: float = 0.04
const _WOBBLE_HZ: float = 10.0

var _fuse_remaining: float = _DEFAULT_FUSE_SEC
var _velocity: Vector3 = Vector3.ZERO
var _chunk_manager: Node
var _ray_query: PhysicsRayQueryParameters3D
var _mesh: MeshInstance3D
# Smoke trail child — vanilla kr.java:51 emits one "smoke" particle per
# tick from the entity's center+0.5y. Continuous CPUParticles3D set up
# by ExplosionFx.build_smoke_trail; freed implicitly when this entity
# queue_frees on detonation.
var _smoke_trail: CPUParticles3D


# fuse_seconds: optional override. Chain-reaction primings pass a
# shorter fuse (0.5–1.5 s) per Alpha v.java::c(). Player ignitions and
# fire-adjacency-ignitions get the default 4 seconds.
func setup(fuse_seconds: float = _DEFAULT_FUSE_SEC) -> void:
	_fuse_remaining = fuse_seconds
	_mesh = MeshInstance3D.new()
	_mesh.mesh = BlockMesh.get_cube_mesh(Blocks.TNT, _MESH_SIZE)
	add_child(_mesh)
	# Spawn impulse — small horizontal jitter so stacked primed TNTs
	# don't stay perfectly aligned during their fuse, plus an upward
	# kick that lifts the entity out of its origin cell. Vanilla
	# kr.java:18-21 uses an unbiased random angle.
	var angle: float = randf() * TAU
	_velocity = Vector3(
		-cos(angle) * _SPAWN_HORIZONTAL_KICK,
		_SPAWN_VERTICAL_KICK,
		-sin(angle) * _SPAWN_HORIZONTAL_KICK,
	)
	_ray_query = PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	# Exclude the player from the ground-collision raycast so we land on
	# terrain even if the player is standing on the spawn cell. Same trick
	# FallingBlock uses.
	var player: CharacterBody3D = get_tree().root.get_node_or_null("Main/Player") as CharacterBody3D
	if player != null:
		_ray_query.exclude = [player.get_rid()]
	# Smoke trail child — vanilla kr.java:51 emits one smoke particle per
	# tick from the entity center+0.5y. As a child node, the emitter
	# follows the entity through gravity / bounces automatically.
	_smoke_trail = ExplosionFx.build_smoke_trail()
	_smoke_trail.position = Vector3(0, 0.5, 0)
	add_child(_smoke_trail)
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
	_apply_visual_wobble()


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


# Subtle 10 Hz scale wobble during the last second of the fuse. Vanilla
# pulses the texture color via shader; our chunk shader doesn't expose
# a per-mesh tint uniform, so wobble stands in as a visual "imminent"
# cue that's still cheap and frame-rate-stable.
func _apply_visual_wobble() -> void:
	if _mesh == null:
		return
	var wobble_t: float = _DEFAULT_FUSE_SEC - _fuse_remaining
	if _fuse_remaining > 1.0:
		_mesh.scale = Vector3.ONE
		return
	var s: float = 1.0 + sin(wobble_t * TAU * _WOBBLE_HZ) * _WOBBLE_AMP
	_mesh.scale = Vector3(s, s, s)


func _detonate() -> void:
	# Hide the visual mesh BEFORE triggering the explosion so the cube
	# doesn't render one last frame inside the blast cloud (queue_free
	# is deferred to end-of-frame). The explosion itself runs on this
	# stack; we queue_free on return so the entity is alive as the
	# blast's `source` (lets future entity-damage code skip self-damage).
	visible = false
	# Detach the smoke trail and let its in-flight puffs finish naturally
	# instead of vanishing when the entity queue_frees. Reparent to the
	# chunk_manager (lives for the whole session), stop emitting, and
	# schedule its own cleanup on a SceneTreeTimer.
	_release_smoke_trail()
	Explosion.detonate(_chunk_manager, global_position, _EXPLOSION_POWER, self)
	queue_free()


func _release_smoke_trail() -> void:
	if _smoke_trail == null or not is_instance_valid(_smoke_trail):
		return
	var world_pos: Vector3 = _smoke_trail.global_position
	# Reparent to chunk_manager so the smoke survives our queue_free.
	# Without this, child node frees with parent and any in-flight puffs
	# pop out of existence — visible disconnect from the actual blast.
	remove_child(_smoke_trail)
	_chunk_manager.add_child(_smoke_trail)
	_smoke_trail.global_position = world_pos
	_smoke_trail.emitting = false
	var tree: SceneTree = _chunk_manager.get_tree()
	if tree != null:
		var grace := tree.create_timer(2.5)
		grace.timeout.connect(ExplosionFx._free_if_valid.bind(_smoke_trail))
